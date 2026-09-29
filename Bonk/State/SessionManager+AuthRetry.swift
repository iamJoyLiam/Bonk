//
//  SessionManager+AuthRetry.swift
//  Bonk
//
//  Auth retry sheet flow extracted from SessionManager to keep the class body
//  within size limits. Same-file logic, moved verbatim.
//

import os.log
import SwiftData
import SwiftTerm
import SwiftUI

/// A parked `requestAuthRetry` caller, resumable at most once.
///
/// Resuming a `CheckedContinuation` twice is a runtime trap, so a double
/// completion would crash rather than fail a test. Holding the flag here makes
/// "exactly once" an ordinary property: a second resolve is a no-op, and
/// `resolveCount` lets a test observe it.
///
/// This type exists because the original code kept a single continuation on
/// `SessionManager`. Two tabs failing auth meant the second request overwrote
/// the first, and the first caller was never resumed — it stayed suspended for
/// the lifetime of the process, holding its tab in a connecting state with
/// nothing on screen to explain it.
@MainActor
final class AuthRetryWaiter {
    private var continuation: CheckedContinuation<SessionManager.AuthRetryResult?, Never>?
    private(set) var resolveCount = 0

    init(_ continuation: CheckedContinuation<SessionManager.AuthRetryResult?, Never>) {
        self.continuation = continuation
    }

    var isResolved: Bool { continuation == nil }

    /// - Returns: `true` if this call resumed the waiter.
    @discardableResult
    func resolve(_ result: SessionManager.AuthRetryResult?) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        resolveCount += 1
        continuation.resume(returning: result)
        return true
    }
}

// MARK: - SessionManager Auth Retry

extension SessionManager {
    private func promptForPassword(username: String, host: String) async -> String? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = I18n.shared.t(.authFailedTitle)
        let displayUser = username.isEmpty ? "?" : username
        alert.informativeText = "\(displayUser)@\(host)\n\(I18n.shared.t(.authFailedMessage))"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        let field = AutoEnglishSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = I18n.shared.t(.password)
        container.addSubview(field)
        alert.accessoryView = container

        alert.addButton(withTitle: I18n.shared.t(.retry))
        alert.addButton(withTitle: I18n.shared.t(.cancel))
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    /// New auth retry via sheet - shows AuthRetrySheet with full auth methods and raw error detail.
    ///
    /// The waiter is registered **per tab**. A single shared continuation cannot
    /// serve two tabs: the second request would overwrite the first, and the
    /// first caller would never be resumed.
    ///
    /// The sheet can only present one request at a time, so a request that is
    /// superseded is unanswerable. It is therefore released as cancelled at the
    /// moment it is superseded, rather than parked waiting for an answer that
    /// can never arrive.
    func requestAuthRetry(for tab: TerminalTab, rawError: String) async -> AuthRetryResult? {
        let last = lastRetryPassword[tab.id]
        return await withCheckedContinuation { continuation in
            // Release anything this request displaces: another tab's, or an
            // earlier request for this same tab. An unreferenced continuation is
            // never resumed, and its caller hangs.
            var superseded: [UUID] = []
            if let visible = visibleAuthRetryTabID, visible != tab.id {
                superseded.append(visible)
            }
            if authRetryWaiters[tab.id] != nil {
                superseded.append(tab.id)
            }
            for tabID in superseded {
                authRetryWaiters.removeValue(forKey: tabID)?.resolve(nil)
            }
            authRetryWaiters[tab.id] = AuthRetryWaiter(continuation)
            authRetryRequest = AuthRetryRequest(
                tab: tab,
                host: tab.hostItem,
                rawError: rawError,
                lastAttemptPassword: last
            )
        }
    }

    /// The tab whose request is currently on screen, if any.
    private var visibleAuthRetryTabID: UUID? { authRetryRequest?.tab.id }

    func completeAuthRetry(with result: AuthRetryResult?) {
        guard let tabID = visibleAuthRetryTabID else { return }
        if let authResult = result, !authResult.password.isEmpty {
            lastRetryPassword[tabID] = authResult.password
        }
        // Resolve the waiter that belongs to *this* request's tab, not
        // whichever waiter happens to be registered.
        authRetryWaiters.removeValue(forKey: tabID)?.resolve(result)
        authRetryRequest = nil
    }

    func completeAuthRetry(with host: HostItem) {
        let result = AuthRetryResult(password: host.loadPassword() ?? "", privateKeyPEM: host.loadPrivateKey() ?? "", certificatePEM: host.loadCertificate() ?? "", secureEnclaveTag: host.loadSecureEnclaveKeyTag(), credentialID: host.credentialRef?.persistentModelID, authType: host.authType)
        completeAuthRetry(with: result)
    }

    func cancelAuthRetry() {
        completeAuthRetry(with: nil)
    }

    /// Release every parked waiter. Used when the manager is torn down, so no
    /// caller is left suspended on a deallocated owner.
    func cancelAllAuthRetries() {
        let waiters = authRetryWaiters
        authRetryWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resolve(nil) }
        authRetryRequest = nil
    }

    /// Typed auth failure from reconnect PTY (not via setupPTYSession) must show sheet
    /// Citadel throws sync, OpenSSH tails async; Prompts=1 fails fast to sheet
    func handleServiceAuthFailure(_ failure: SSHFailure, for tab: TerminalTab) async {
        guard tabs.contains(where: { $0.id == tab.id }), let session = tab.session else { return }
        guard case let .authentication(authFailure) = failure else { return }
        let display = SSHErrorMessageParser.explain(authFailure.message, host: tab.hostItem.host, jumpHost: tab.hostItem.jumpHostRef?.host) ?? authFailure.message
        // Single sheet path
        if case .authentication = session.failureReason, session.phase == .failed(display), isShowingDialog(for: tab.id) { return }
        session.failureReason = failure
        setPhase(session, to: .failed(display), host: tab.hostItem.host, engine: "OpenSSH", reason: "authFailed")
        session.signalAuthFailure()
        session.errorMessage = display
        Log.session.error("[SSH_FAILURE] type=authentication backend=openssh (service) msg=\(display.prefix(120), privacy: .public)")
        Log.session.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed (service)")
        guard !isShowingDialog(for: tab.id) else { return }
        setShowingDialog(true, for: tab.id)
        defer { setShowingDialog(false, for: tab.id) }
        if retryState(for: tab.id) == .dialogShown {
            Log.session.error("[AUTH_RETRY] service reconnect failed; cleaning")
            OpenSSHBackend.cleanupOrphanedMuxes()
            setRetryState(.cleanupDone, for: tab.id)
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            sessionStore.markConnected(tab.id)
            let reuse = transientAuthResults[tab.id]
            if let reuseResult = reuse, reuseResult.authType == .password, !reuseResult.password.isEmpty {
                await connectTab(tab, passwordOverride: reuseResult.password, ephemeralResult: reuseResult, resetAuthRetry: false)
            } else {
                await connectTab(tab, ephemeralResult: reuse, resetAuthRetry: false)
            }
            if case .failed = tab.session?.phase {
                // Keep cleanupDone for next failure
            } else {
                setRetryState(.idle, for: tab.id)
            }
            return
        }
        if retryState(for: tab.id) == .cleanupDone {
            Log.session.error("[AUTH_RETRY] service second failure; re-show sheet")
            setRetryState(.idle, for: tab.id)
        }
        setRetryState(.dialogShown, for: tab.id)
        guard let result = await requestAuthRetry(for: tab, rawError: authFailure.message) else {
            setRetryState(.idle, for: tab.id); return
        }
        let passwordLength = result.password.count
        let fingerprint = passwordLength > 0 ? OpenSSHBackend.passwordFingerprint(result.password) : "-"
        Log.session.info("[AUTH_RETRY] source=ephemeral (service) passwordLength=\(passwordLength) passwordFingerprint=\(fingerprint, privacy: .public) authType=\(result.authType.rawValue, privacy: .public)")
        transientAuthResults[tab.id] = result
        // Isolated retry via ControlMaster bypass
        if result.authType == .password, !result.password.isEmpty {
            await connectTab(tab, passwordOverride: result.password, ephemeralResult: result, resetAuthRetry: false)
        } else {
            await connectTab(tab, ephemeralResult: result, resetAuthRetry: false)
        }
        if case .failed = tab.session?.phase {
            transientAuthResults[tab.id] = nil
        } else {
            setRetryState(.idle, for: tab.id)
        }
    }
}
