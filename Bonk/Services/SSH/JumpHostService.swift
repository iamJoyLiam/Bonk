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

    /// Test connection to a jump host using plain values — deliberately does
    /// NOT take a JumpHost model object, so testing never creates or persists
    /// a SwiftData record.
    ///
    /// Throws on failure so the caller can surface the real SSH error
    /// (bad credentials, unreachable host, forwarding disabled, etc.)
    /// instead of a generic "connection failed".
    func testConnection(
        host: String,
        port: Int,
        username: String,
        authMethod: SSHAuthMethod
    ) async throws {
        // Create SSH connection config for the jump host
        let config = SSHConnectionConfig(
            host: host,
            port: UInt16(port),
            username: username,
            authMethod: authMethod,
            maxReconnectAttempts: 0,
            baseReconnectDelay: .seconds(1)
        )

        // Try to connect
        let service = SSHNetworkService(hostKeyStore: PersistentHostKeyStore())
        do {
            try await service.connect(config: config)
            _ = try await service.executeCommand("true")
            await service.disconnect()
        } catch {
            await service.disconnect()
            throw error
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
