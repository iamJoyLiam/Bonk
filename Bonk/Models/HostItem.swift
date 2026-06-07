import Foundation
import SwiftData

/// Authentication method for SSH connections.
enum AuthType: String, Codable {
    case password
    case privateKey
}

/// Persisted SSH host configuration.
/// Credentials are stored in Keychain, not in SwiftData.
@Model
final class HostItem {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authTypeRaw: String
    var createdAt: Date
    var lastConnectedAt: Date?

    @Relationship(deleteRule: .nullify)
    var groupRef: HostGroup?
    @Relationship(deleteRule: .nullify)
    var credentialRef: Credential?

    var authType: AuthType {
        get { AuthType(rawValue: authTypeRaw) ?? .password }
        set { authTypeRaw = newValue.rawValue }
    }

    // MARK: - Keychain credentials

    func loadPassword() -> String? {
        KeychainHelper.get(for: KeychainHelper.passwordKey(for: id))
    }

    func loadPasswordSecure() -> SecureBytes? {
        KeychainHelper.getSecure(for: KeychainHelper.passwordKey(for: id))
    }

    func storePassword(_ password: String) {
        guard !password.isEmpty else { return }
        KeychainHelper.set(password, for: KeychainHelper.passwordKey(for: id))
    }

    func loadPrivateKey() -> String? {
        KeychainHelper.get(for: KeychainHelper.privateKeyKey(for: id))
    }

    func loadPrivateKeySecure() -> SecureBytes? {
        KeychainHelper.getSecure(for: KeychainHelper.privateKeyKey(for: id))
    }

    func storePrivateKey(_ pem: String) {
        guard !pem.isEmpty else { return }
        KeychainHelper.set(pem, for: KeychainHelper.privateKeyKey(for: id))
    }

    init(
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authType: AuthType = .password,
        password: String? = nil,
        privateKeyPEM: String? = nil,
        groupRef: HostGroup? = nil,
        credentialRef: Credential? = nil
    ) {
        id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        authTypeRaw = authType.rawValue
        createdAt = Date()
        self.groupRef = groupRef
        self.credentialRef = credentialRef

        if let passwordValue = password { storePassword(passwordValue) }
        if let pem = privateKeyPEM { storePrivateKey(pem) }
    }

    func deleteCredentials() {
        KeychainHelper.delete(for: KeychainHelper.passwordKey(for: id))
        KeychainHelper.delete(for: KeychainHelper.privateKeyKey(for: id))
    }

    /// Resolve the effective username.
    func resolveUsername(modelContext _: ModelContext) -> String {
        if let cred = credentialRef,
           let credUsername = cred.username, !credUsername.isEmpty {
            return credUsername
        }
        return username
    }

    /// Resolve the effective SSH auth method.
    func resolveAuthMethod(modelContext _: ModelContext) -> SSHAuthMethod? {
        // 1. Try vault credential
        if let cred = credentialRef,
           let secret = cred.loadSecret(), !secret.isEmpty {
            switch cred.type {
            case .password:
                return .password(secret)
            case .privateKey:
                return .privateKey(pemString: secret)
            case .apiKey:
                return nil
            }
        }

        // 2. Fall back to host-embedded credentials
        switch authType {
        case .password:
            guard let password = loadPassword(), !password.isEmpty else { return nil }
            return .password(password)
        case .privateKey:
            guard let pem = loadPrivateKey(), !pem.isEmpty else { return nil }
            return .privateKey(pemString: pem)
        }
    }
}
