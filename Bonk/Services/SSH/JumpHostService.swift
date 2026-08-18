//
//  JumpHostService.swift
//  Bonk
//
//  Jump host (bastion) connection service for multi-hop SSH.
//

import Foundation
import os.log

/// Jump host connection service for multi-hop SSH connections.
@Observable @MainActor
final class JumpHostService {
    static let shared = JumpHostService()

    private let logger = Logger(subsystem: "com.bonk", category: "JumpHost")

    /// Test connection to a jump host.
    func testConnection(jumpHost: JumpHost, credential: SSHAuthMethod) async throws -> Bool {
        // Create SSH connection config for the jump host
        let config = SSHConnectionConfig(
            host: jumpHost.host,
            port: UInt16(jumpHost.port),
            username: jumpHost.username,
            authMethod: credential,
            maxReconnectAttempts: 0,
            baseReconnectDelay: .seconds(1)
        )

        // Try to connect
        let service = SSHNetworkService(hostKeyStore: PersistentHostKeyStore())
        do {
            try await service.connect(config: config)
            _ = try await service.executeCommand("true")
            await service.disconnect()
            return true
        } catch {
            return false
        }
    }

    /// Get the SSH connection config for connecting through a jump host.
    func createTunnelConfig(
        jumpHost: JumpHost,
        targetHost: String,
        targetPort: Int,
        jumpCredential: SSHAuthMethod,
        targetCredential: SSHAuthMethod,
        targetUsername: String? = nil
    ) -> SSHConnectionConfig {
        SSHConnectionConfig(
            host: targetHost,
            port: UInt16(targetPort),
            username: targetUsername ?? jumpHost.username,
            authMethod: targetCredential,
            jumpHost: SSHJumpHostConfig(
                host: jumpHost.host,
                port: UInt16(jumpHost.port),
                username: jumpHost.username,
                authMethod: jumpCredential
            ),
            maxReconnectAttempts: 3,
            baseReconnectDelay: .seconds(1)
        )
    }
}
