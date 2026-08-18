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
        let parsed = SSHHostParser.parse(host.host)
        let effectivePort = parsed.port ?? host.port
        let effectiveHost = parsed.host.isEmpty ? host.host : parsed.host
        let resolvedUsername = host.resolveUsername()
        let effectiveUsername = resolvedUsername.isEmpty
            ? (parsed.username ?? "")
            : resolvedUsername

        guard (1 ... 65535).contains(effectivePort) else {
            return .failure(ConnectionConfigError(message: I18n.shared.t(.invalidPort)))
        }
        guard let authMethod = host.resolveAuthMethod() else {
            return .failure(ConnectionConfigError(message: I18n.shared.t(.credentialsNotSet)))
        }
        guard !effectiveUsername.isEmpty else {
            return .failure(ConnectionConfigError(message: I18n.shared.t(.credentialsNotSet)))
        }
        let jumpConfig = host.jumpHostRef.map {
            SSHJumpHostConfig(
                host: $0.host,
                port: UInt16(max(1, min($0.port, 65535))),
                username: $0.username,
                authMethod: $0.resolveAuthMethod()
            )
        }
        return .success(
            SSHConnectionConfig(
                host: effectiveHost,
                port: UInt16(effectivePort),
                username: effectiveUsername,
                authMethod: authMethod,
                jumpHost: jumpConfig,
                maxReconnectAttempts: 0,
                baseReconnectDelay: .seconds(1)
            )
        )
    }
}
