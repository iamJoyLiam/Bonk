//
//  OpenSSHAuthPromptResponder.swift
//  Bonk
//
//  Bridges OpenSSH terminal prompts to saved credentials and MFA UI.
//

#if os(macOS)

import Foundation
import os.log

/// Responds to authentication prompts emitted by an OpenSSH PTY.
///
/// Saved passwords are offered once. Further password prompts remain visible
/// so a user can correct a stale credential in the terminal. MFA prompts use
/// the same NSAlert controller as native keyboard-interactive auth.
struct OpenSSHPasswordCredential: Sendable, Equatable {
    let username: String
    let host: String
    let password: String
}

final class OpenSSHAuthPromptResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var promptBuffer = ""
    private var credentials: [OpenSSHPasswordCredential]
    /// Generic `Password:` prompts are ambiguous when a ProxyCommand is
    /// active. Only use them for single-hop commands that explicitly allow
    /// automatic password submission.
    private let allowUnscopedPassword: Bool
    private let write: @Sendable (Data) -> Void

    // MARK: - Manual password capture
    //
    // When no saved credential matches (e.g. the stored password was wrong),
    // the prompt stays visible and the user types the password into the
    // terminal. Those keystrokes flow through PTYSession.sendInput and are
    // tapped here; once the server accepts the password (observed as the
    // next output chunk not being a re-prompt), the new password is offered
    // back so the app can update the saved credential.
    //
    // Capture is deliberately scoped: it only activates for the host-auth
    // prompt (one that contains `user@host`, e.g. "root@1.2.3.4's
    // password:"). Prompts like "[sudo] password for root:" or
    // "New password:" never contain a host, so sudo/passwd/mysql passwords
    // can never be mistaken for SSH credentials. A timeout closes the
    // capture window even if the user never types.

    private var awaitingManualPassword = false
    private var manualPasswordBuffer = ""
    private var pendingPassword: String?
    private var captureExpiresAt = Date.distantPast
    private static let captureTimeout: TimeInterval = 30
    /// Deadline after which a submitted password counts as accepted, PROVIDED
    /// no rejection signal (Permission denied / re-prompt) appeared meanwhile.
    /// Without this window the single next chunk (which may be an empty echo
    /// or control sequence) triggered a false "accepted", even when the
    /// server had actually rejected the password.
    private var passwordResultDeadline = Date.distantPast

    /// Called with a manually typed password once the server has accepted it.
    var onManualPasswordVerified: (@Sendable (String) -> Void)?

    /// `user@host` values that identify this connection's own auth prompts.
    private let authUserHosts: [String]

    init(
        credentials: [OpenSSHPasswordCredential],
        authUserHosts: [String],
        allowInteractivePrompt: Bool,
        allowUnscopedPassword: Bool,
        write: @escaping @Sendable (Data) -> Void
    ) {
        self.credentials = credentials.filter { !$0.password.isEmpty }
        self.authUserHosts = authUserHosts
        self.allowUnscopedPassword = allowUnscopedPassword
        self.write = write
    }

    func observe(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

        lock.lock()
        promptBuffer.append(text)
        let normalized = Self.stripANSI(promptBuffer)
        let suffix = String(normalized.suffix(256))
        lock.unlock()

        // A manually typed password is pending: decide acceptance over a short
        // window, not a single chunk. The server's rejection
        // ("Permission denied, please try again.") may arrive split across
        // chunks or after an empty/control-sequence chunk — judging on the
        // first chunk alone caused a false "accepted" (and a spurious
        // credential update) right before the connection failed.
        if let pending = pendingPassword {
            let fresh = Self.stripANSI(text)
            if containsPermissionDenied(fresh)
                || fresh.range(
                    of: #"(?i)(password|passphrase)\s*:\s*$"#,
                    options: .regularExpression
                ) != nil
            {
                // Rejected — abandon the capture, wait for the next try.
                pendingPassword = nil
                awaitingManualPassword = true
                passwordResultDeadline = .distantPast
            } else if Date() >= passwordResultDeadline {
                // No rejection within the window: the password was accepted.
                pendingPassword = nil
                awaitingManualPassword = false
                passwordResultDeadline = .distantPast
                os_log("Manual password accepted, offering for save", type: .info)
                onManualPasswordVerified?(pending)
            }
            // else: keep waiting for the rejection signal within the window.
        }

        if matchesPasswordPrompt(suffix) {
            if respondPasswordIfAvailable(for: suffix) {
                return
            }

            // No saved credential left — the prompt stays visible and the
            // user types the password into the terminal. Keystrokes are
            // captured for the credential-update flow, but only for host-auth
            // prompts (containing `user@host`); sudo/passwd/mysql prompts
            // never contain a host, so they can never be mistaken.
            if promptContainsAuthHost(suffix) {
                awaitingManualPassword = true
                manualPasswordBuffer = ""
                captureExpiresAt = Date().addingTimeInterval(Self.captureTimeout)
            }
            return
        }
    }

    /// Tap bytes the user types into the terminal. Only captured while a
    /// manual password prompt is awaiting input (no-echo, so the password
    /// never appears on screen).
    func observeInput(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        defer { lock.unlock() }
        guard awaitingManualPassword else { return }
        guard Date() < captureExpiresAt else {
            awaitingManualPassword = false
            manualPasswordBuffer = ""
            return
        }

        let data = Data(bytes)
        if data.contains(0x0A) || data.contains(0x0D) {
            // Enter — submit whatever was captured.
            if !manualPasswordBuffer.isEmpty {
                pendingPassword = manualPasswordBuffer
                // Allow a 2s window for the server's rejection signal.
                passwordResultDeadline = Date().addingTimeInterval(2)
                manualPasswordBuffer = ""
            }
            awaitingManualPassword = false
        } else if data.contains(0x7F) || data.contains(0x08) {
            // Backspace in the captured buffer.
            manualPasswordBuffer = String(manualPasswordBuffer.dropLast())
        } else if let text = String(data: data, encoding: .utf8) {
            manualPasswordBuffer += text
        }
    }

    private func containsPermissionDenied(_ text: String) -> Bool {
        text.range(of: #"(?i)permission denied"#, options: .regularExpression) != nil
    }

    /// Whether the prompt is this connection's own auth prompt — it must
    /// contain a known `user@host` so sudo/passwd/mysql prompts (which
    /// never include a host) cannot open the capture window.
    private func promptContainsAuthHost(_ text: String) -> Bool {
        guard !authUserHosts.isEmpty else { return false }
        let lower = text.lowercased()
        return authUserHosts.contains { lower.contains($0.lowercased()) }
    }

    @discardableResult
    private func respondPasswordIfAvailable(for prompt: String) -> Bool {
        lock.lock()
        let promptLowercased = prompt.lowercased()
        let credentialIndex = credentials.firstIndex {
            let userHost = "\($0.username)@\($0.host)".lowercased()
            return promptLowercased.contains(userHost)
        } ?? (allowUnscopedPassword && credentials.count == 1 ? 0 : nil)

        guard let credentialIndex else {
            lock.unlock()
            return false
        }

        let credential = credentials.remove(at: credentialIndex)
        promptBuffer = ""
        lock.unlock()

        write(Data((credential.password + "\n").utf8))
        return true
    }

    private func matchesPasswordPrompt(_ text: String) -> Bool {
        text.range(
            of: #"(?i)(password|passphrase)\s*:\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func stripANSI(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#,
                with: "",
                options: .regularExpression
            )
    }
}

#endif
