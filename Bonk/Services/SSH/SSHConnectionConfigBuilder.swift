import Foundation

/// User-presentable connection config error.
struct ConnectionConfigError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// Builds an SSH connection config from a saved host.
/// Shared by the normal tab connect flow and the AI agent's on-demand
/// connections, so both go through the same validation and credential path.
enum SSHConnectionConfigBuilder {
    static func makeConfig(for host: HostItem) -> Result<SSHConnectionConfig, ConnectionConfigError> {
        guard (1 ... 65535).contains(host.port) else {
            return .failure(ConnectionConfigError(message: I18n.shared.t(.invalidPort)))
        }
        guard let authMethod = host.resolveAuthMethod() else {
            return .failure(ConnectionConfigError(message: I18n.shared.t(.credentialsNotSet)))
        }
        return .success(
            SSHConnectionConfig(
                host: host.host,
                port: UInt16(host.port),
                username: host.resolveUsername(),
                authMethod: authMethod,
                maxReconnectAttempts: 0,
                baseReconnectDelay: .seconds(1)
            )
        )
    }
}
