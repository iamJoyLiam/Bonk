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
    var outputStream: AsyncStream<String>?
    var connectedAt: Date?
    var errorMessage: String?
    var serverInfo: ServerInfo?
    var stateObservationTask: Task<Void, Never>?
    var serverInfoTask: Task<Void, Never>?

    var isConnected: Bool { connectionState.isConnected }

    init(tabID: UUID) {
        self.tabID = tabID
    }

    /// Tear down all connection resources.
    func disconnect() {
        stateObservationTask?.cancel()
        serverInfoTask?.cancel()
        stateObservationTask = nil
        serverInfoTask = nil
        sftpService = nil
        ptySession?.close()
        ptySession = nil
        sshService = nil
        outputStream = nil
        connectedAt = nil
        serverInfo = nil
        connectionState = .disconnected
    }
}
