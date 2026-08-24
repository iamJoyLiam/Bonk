//
//  SSHRequirementsMapper.swift
//  Bonk
//
//  VNext — HostItem / SSHConnectionConfig → SSHConnectionRequirements (T2.1).
//

import Foundation

enum SSHRequirementsMapper {
    static func requirements(
        from config: SSHConnectionConfig,
        service: SSHServiceRequirement = .terminal
    ) -> SSHConnectionRequirements {
        let auth = routingAuth(from: config.authMethod)
        let keyAlgo = keyAlgorithm(from: config.authMethod)
        let route = route(from: config.jumpHost)
        return SSHConnectionRequirements(
            authentication: auth,
            keyAlgorithm: keyAlgo,
            requiresKeyboardInteractive: false,
            requiresCertificate: auth == .certificate,
            requiresAgent: auth == .agent,
            route: route,
            service: service,
            endpoint: SSHEndpoint(host: config.host, port: config.port)
        )
    }

    static func requirements(
        from host: HostItem,
        service: SSHServiceRequirement = .terminal
    ) -> SSHConnectionRequirements? {
        guard let config = try? SSHConnectionConfigBuilder.makeConfig(for: host).get() else { return nil }
        return requirements(from: config, service: service)
    }

    // MARK: - Private

    private static func routingAuth(from method: SSHAuthMethod) -> SSHRoutingAuthMethod {
        switch method {
        case .password: return .password
        case .privateKey: return .publicKey
        case .certificate: return .certificate
        case .secureEnclaveKey: return .secureEnclave
        }
    }

    private static func keyAlgorithm(from method: SSHAuthMethod) -> SSHKeyAlgorithm? {
        switch method {
        case .password, .secureEnclaveKey:
            return nil
        case .privateKey(let pem):
            // Best-effort PEM inspection — defaults to ed25519 (Citadel's primary)
            let lower = pem.lowercased()
            if lower.contains("rsa") { return .rsa }
            if lower.contains("ecdsa") || lower.contains("ec private") { return .ecdsa }
            return .ed25519
        case .certificate(let pem, _):
            let lower = pem.lowercased()
            if lower.contains("rsa") { return .rsa }
            if lower.contains("ecdsa") { return .ecdsa }
            return .ed25519
        }
    }

    private static func route(from jump: SSHJumpHostConfig?) -> SSHRoute {
        guard let jumpHost = jump else { return .direct }
        return SSHRoute(hops: [SSHEndpoint(host: jumpHost.host, port: jumpHost.port)])
    }
}
