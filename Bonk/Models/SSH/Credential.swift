import Foundation
import SwiftData

enum CredentialType: String, Codable, CaseIterable {
    case password, privateKey, apiKey

    func displayName(_ i18n: I18n) -> String {
        switch self {
        case .password: i18n.t(.password)
        case .privateKey: i18n.t(.privateKey)
        case .apiKey: i18n.t(.apiKey)
        }
    }

    var symbolName: String {
        switch self {
        case .password: "key.fill"
        case .privateKey: "lock.doc.fill"
        case .apiKey: "sparkles"
        }
    }
}

@Model
final class Credential {
    var keychainID: UUID // stable identifier for Keychain, never changes
    var name: String
    var typeRaw: String
    var username: String?
    var createdAt: Date
    var notes: String?

    @Relationship(inverse: \HostItem.credentialRef)
    var hosts: [HostItem]

    var type: CredentialType {
        get { CredentialType(rawValue: typeRaw) ?? .password }
        set { typeRaw = newValue.rawValue }
    }

    init(name: String, type: CredentialType = .password, username: String? = nil, notes: String? = nil) {
        keychainID = UUID()
        self.name = name
        typeRaw = type.rawValue
        self.username = username
        createdAt = Date()
        self.notes = notes
        hosts = []
    }

    // MARK: - Keychain (explicit, no silent I/O in computed property)

    private var keychainAccount: String {
        "credential_\(keychainID.uuidString)"
    }

    func loadSecret() -> String? {
        KeychainHelper.get(for: keychainAccount)
    }

    /// Load secret into a secure buffer that auto-zeroes on deallocation.
    /// Prefer this over `loadSecret()` for auth flows.
    func loadSecretSecure() -> SecureBytes? {
        KeychainHelper.getSecure(for: keychainAccount)
    }

    func storeSecret(_ secret: String) {
        guard !secret.isEmpty else { return }
        KeychainHelper.set(secret, for: keychainAccount)
    }

    func deleteSecret() {
        KeychainHelper.delete(for: keychainAccount)
    }
}
