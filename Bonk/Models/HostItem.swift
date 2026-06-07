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
    var group: String?
    /// Optional reference to a shared vault credential. When set, connection
    /// uses the vault credential instead of host-embedded password/privateKeyPEM.
    var credentialID: String?

    // MARK: - Relationships (v2026.0.4)
    /// Proper SwiftData relationships replacing string-based references above.
    @Relationship(deleteRule: .nullify)
    var groupRef: HostGroup?
    @Relationship(deleteRule: .nullify)
    var credentialRef: Credential?

    var authType: AuthType {
        get { AuthType(rawValue: authTypeRaw) ?? .password }
        set { authTypeRaw = newValue.rawValue }
    }

    // MARK: - Keychain credentials (explicit methods, no silent I/O)

    func loadPassword() -> String? {
        KeychainHelper.get(for: KeychainHelper.passwordKey(for: id))
    }

    /// Load password into a secure buffer that auto-zeroes on deallocation.
    /// Prefer this over `loadPassword()` for auth flows.
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

    /// Load private key into a secure buffer that auto-zeroes on deallocation.
    /// Prefer this over `loadPrivateKey()` for auth flows.
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
        group: String? = nil,
        credentialID: String? = nil
    ) {
        id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        authTypeRaw = authType.rawValue
        createdAt = Date()
        self.group = group
        self.credentialID = credentialID

        if let passwordValue = password { storePassword(passwordValue) }
        if let pem = privateKeyPEM { storePrivateKey(pem) }
    }

    /// Remove credentials from Keychain when host is deleted.
    func deleteCredentials() {
        KeychainHelper.delete(for: KeychainHelper.passwordKey(for: id))
        KeychainHelper.delete(for: KeychainHelper.privateKeyKey(for: id))
    }

    /// Resolve the effective username.
    /// Checks vault credential's username first, then falls back to host-embedded username.
    func resolveUsername(modelContext: ModelContext) -> String {
        if let credName = credentialID {
            let descriptor = FetchDescriptor<Credential>(predicate: #Predicate { $0.name == credName })
            if let cred = try? modelContext.fetch(descriptor).first,
               let credUsername = cred.username, !credUsername.isEmpty {
                return credUsername
            }
        }
        return username
    }

    /// Resolve the effective SSH auth method.
    /// Checks vault credential first, then falls back to host-embedded credentials.
    func resolveAuthMethod(modelContext: ModelContext) -> SSHAuthMethod? {
        // 1. Try vault credential
        if let credName = credentialID {
            let name = credName
            let descriptor = FetchDescriptor<Credential>(predicate: #Predicate { $0.name == name })
            if let cred = try? modelContext.fetch(descriptor).first,
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
