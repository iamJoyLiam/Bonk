import Foundation

/// Active connection state for a terminal tab.
/// Separated from TerminalTab so the model holds display state,
/// while transient connection resources are lifecycle-managed here.
@Observable @MainActor
final class TerminalSession {
    let tabID: UUID
    var connectionState: SSHConnectionState = .disconnected
    var sshService: SSHNetworkService?
    var ptySession: PTYSession?
    var sftpService: SFTPService?
    private var sftpConnectionTask: Task<SFTPService, Error>?
    var vnextSession: (any SSHSession)?
    var sftpErrorMessage: String?
    var outputStream: AsyncStream<String>?
    var connectedAt: Date?
    var errorMessage: String?
    var serverInfo: ServerInfo?
    var commandHistory = CommandHistory()
    /// Accumulated input buffer for command history recording.
    var inputBuffer: String = ""
    var stateObservationTask: Task<Void, Never>?
    /// Whether this session owns the SSH service (and should disconnect it on teardown).
    /// false when created via unsplitPane (shares SSH connection with another tab).
    var ownsSSHService = true

    var isConnected: Bool {
        connectionState.isConnected
    }

    var isSFTPConnecting: Bool {
        sftpConnectionTask != nil
    }

    init(tabID: UUID) {
        self.tabID = tabID
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
        stateObservationTask?.cancel()
        stateObservationTask = nil
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
