import Foundation

/// Active connection state for a terminal tab.
/// Separated from TerminalTab so the model holds display state,
/// while transient connection resources are lifecycle-managed here.
@Observable @MainActor
final class TerminalSession {
    let tabID: UUID
    var connectionState: SSHConnectionState = .disconnected
    var phase: SSHConnectionPhase = .idle
    var terminalState: TerminalState = .idle
    var sshService: SSHNetworkService?
    var ptySession: PTYSession?
    var sftpService: SFTPService?
    private var sftpConnectionTask: Task<SFTPService, Error>?
    var vnextSession: (any SSHSession)?
    var sftpErrorMessage: String?
    var outputStream: AsyncStream<String>?
    var connectedAt: Date?
    var errorMessage: String?
    /// 全链路 generation — 与 SSHConnectionConfig.generation 互通，用于旧 Attempt 丢弃
    var generation: UUID = UUID()
    /// Typed failure for Recovery gate — authenticationFailed NEVER recovery
    var failureReason: SSHFailure?
    /// Deterministic PTY auth outcome signal — replaces unreliable 2s polling.
    /// `finalizeConnection` installs a continuation; `onFailure` callbacks resume it.
    /// `true` = auth failure detected; `false` = timeout (no failure, assume success).
    private var authFailureContinuation: CheckedContinuation<Bool, Never>?
    /// If auth fails before waiter is installed, remember it so next waiter returns immediately.
    private var pendingAuthFailed: Bool = false

    /// Install a one-shot waiter for PTY auth failure. Returns true if auth failed within the timeout.
    func awaitAuthFailure(timeout: Duration) async -> Bool {
        // If failure already arrived before waiter, return immediately (fix lost-signal race)
        if pendingAuthFailed {
            pendingAuthFailed = false
            return true
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.authFailureContinuation = cont
            Task {
                try? await Task.sleep(for: timeout)
                await MainActor.run {
                    if let pending = self.authFailureContinuation {
                        self.authFailureContinuation = nil
                        pending.resume(returning: false)
                    }
                }
            }
        }
    }

    /// Signal that an auth failure was detected (called from onFailure callbacks).
    func signalAuthFailure() {
        if let cont = authFailureContinuation {
            authFailureContinuation = nil
            cont.resume(returning: true)
        } else {
            // Waiter not yet installed — remember for next await (fix race where PTY exits before finalize installs waiter)
            pendingAuthFailed = true
        }
    }

    /// Cancel any pending auth failure waiter (on disconnect/generation change).
    func cancelAuthFailureWaiter() {
        pendingAuthFailed = false
        if let cont = authFailureContinuation {
            authFailureContinuation = nil
            cont.resume(returning: false)
        }
    }
    var serverInfo: ServerInfo?
    var commandHistory = CommandHistory()
    /// Accumulated input buffer for command history recording.
    var inputBuffer: String = ""
    var stateObservationTask: Task<Void, Never>?
    var stateObserverToken = UUID()
    /// Whether this session owns the SSH service (and should disconnect it on teardown).
    /// false when created via unsplitPane (shares SSH connection with another tab).
    var ownsSSHService = true

    var isConnected: Bool {
        connectionState.isConnected
    }

    var isReady: Bool {
        phase.isReady && ptySession != nil
    }

    var isSFTPConnecting: Bool {
        sftpConnectionTask != nil
    }

    init(tabID: UUID) {
        self.tabID = tabID
    }

    /// v3.3 Hybrid exec — prefers multiplexed SSHSession (Native or Compatibility)
    /// over the legacy SSHNetworkService path. One connection, many exec channels.
    func executeHybrid(_ command: String) async throws -> String {
        if let vnext = vnextSession {
            let result = try await vnext.execute(command)
            return result.output
        }
        guard let sshService else { throw SSHServiceError.notConnected }
        return try await sshService.executeCommand(command)
    }

    /// Return the existing SFTP service, or coalesce concurrent connection
    /// requests into one native SFTP handshake.
    func ensureSFTP() async -> SFTPService? {
        if let sftpService {
            return sftpService
        }

        if let sftpConnectionTask {
            return try? await sftpConnectionTask.value
        }

        // VNext T5 — prefer unified session if available (single-connection multiplex)
        if let vnextSession {
            sftpErrorMessage = nil
            let task = Task { @MainActor in
                let service = SFTPService()
                try await service.connect(using: vnextSession)
                return service
            }
            sftpConnectionTask = task
            defer { sftpConnectionTask = nil }
            do {
                let service = try await task.value
                sftpService = service
                sftpErrorMessage = nil
                return service
            } catch {
                sftpErrorMessage = error.localizedDescription
                return nil
            }
        }

        guard let sshService else { return nil }

        sftpErrorMessage = nil
        let task = Task { @MainActor in
            let service = SFTPService()
            try await service.connect(using: sshService)
            return service
        }
        sftpConnectionTask = task

        defer { sftpConnectionTask = nil }

        do {
            let service = try await task.value
            sftpService = service
            sftpErrorMessage = nil
            return service
        } catch {
            sftpErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Tear down all connection resources.
    func disconnect() {
        cancelAuthFailureWaiter()
        stateObservationTask?.cancel()
        stateObservationTask = nil
        stateObserverToken = UUID()
        phase = .idle
        terminalState = .closed
        sftpConnectionTask?.cancel()
        sftpConnectionTask = nil
        sftpService = nil
        sftpErrorMessage = nil
        vnextSession = nil
        ptySession?.close()
        ptySession = nil
        // Only disconnect SSH service if this session owns it
        if ownsSSHService {
            sshService = nil
        }
        outputStream = nil
        connectedAt = nil
        serverInfo = nil
        connectionState = .disconnected
    }
}
