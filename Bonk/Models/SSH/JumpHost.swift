//
//  JumpHost.swift
//  Bonk
//

import Foundation
import SwiftData

/// A jump host (bastion) configuration for multi-hop SSH connections.
@Model
final class JumpHost {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: String
    /// Deprecated — kept for migration, use `credentialRef`.
    var credentialID: UUID?
    @Relationship(deleteRule: .nullify)
    var credentialRef: Credential?
    @Relationship(inverse: \HostItem.jumpHostRef)
    var targetHosts: [HostItem]
    var sortOrder: Int
    var createdAt: Date

    init(
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authType: String = "password"
    ) {
        id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        targetHosts = []
        sortOrder = 0
        createdAt = Date()
    }

    /// Display string for the jump host.
    var displayString: String {
        "\(username)@\(host):\(port)"
    }

    // MARK: - Inline Keychain credentials
    //
    // A jump host can authenticate with a password or private key stored
    // directly (per-jump-host Keychain entries), or by referencing a vault
    // credential. `authType` records which one is in use: "password",
    // "privateKey" or "credential" (vault reference, default).

    func loadPassword() -> String? {
        KeychainHelper.get(for: KeychainHelper.jumpPasswordKey(for: id))
    }

    func storePassword(_ password: String) {
        guard !password.isEmpty else { return }
        KeychainHelper.set(password, for: KeychainHelper.jumpPasswordKey(for: id))
    }

    func loadPrivateKey() -> String? {
        KeychainHelper.get(for: KeychainHelper.jumpPrivateKeyKey(for: id))
    }

    func storePrivateKey(_ pem: String) {
        guard !pem.isEmpty else { return }
        KeychainHelper.set(pem, for: KeychainHelper.jumpPrivateKeyKey(for: id))
    }

    func deleteInlineCredentials() {
        KeychainHelper.delete(for: KeychainHelper.jumpPasswordKey(for: id))
        KeychainHelper.delete(for: KeychainHelper.jumpPrivateKeyKey(for: id))
    }

    func resolveAuthMethod() -> SSHAuthMethod? {
        switch authType {
        case "password":
            if let secret = loadPassword(), !secret.isEmpty {
                return .password(secret)
            }
            // Legacy data: the old editor stored authType="password" (the
            // init default) but authenticated via credentialRef. Fall back
            // to the vault credential instead of dropping auth entirely.
            fallthrough
        case "privateKey":
            if let pem = loadPrivateKey(), !pem.isEmpty {
                return .privateKey(pemString: pem)
            }
            fallthrough
        case "credential":
            guard let credentialRef,
                  let secret = credentialRef.loadSecret(),
                  !secret.isEmpty
            else {
                return nil
            }

            switch credentialRef.type {
            case .password:
                return .password(secret)
            case .privateKey:
                return .privateKey(pemString: secret)
            case .apiKey:
                return nil
            }
        default:
            return nil
        }
    }
}
