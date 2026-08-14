import Foundation
import Observation

/// On-demand SSH connections for the AI agent (v2).
/// Reuses the normal credential path but never creates a tab or PTY — only
/// an exec channel, so the user's terminal layout is untouched.
@Observable @MainActor
final class AgentConnectionService {
    static let shared = AgentConnectionService()

    private(set) var connectedHostID: UUID?
    private(set) var isConnecting = false
    var lastError: String?

    private let hostKeyStore = PersistentHostKeyStore()
    private var service: SSHNetworkService?

    private init() {}

    /// Return the existing live connection for `host`, or connect on demand.
    func service(for host: HostItem) async throws -> SSHNetworkService {
        if let service, connectedHostID == host.id,
           await service.connectionState.isConnected
        {
            return service
        }

        await disconnect()
        isConnecting = true
        defer { isConnecting = false }

        do {
            let config: SSHConnectionConfig
            switch SSHConnectionConfigBuilder.makeConfig(for: host) {
            case .success(let value): config = value
            case .failure(let error): throw error
            }

            let newService = SSHNetworkService(hostKeyStore: hostKeyStore)
            try await newService.connect(config: config)

            service = newService
            connectedHostID = host.id
            lastError = nil
            return newService
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func disconnect() async {
        await service?.disconnect()
        service = nil
        connectedHostID = nil
    }

    func isConnected(to hostID: UUID) async -> Bool {
        guard let service, connectedHostID == hostID else { return false }
        return await service.connectionState.isConnected
    }
}
