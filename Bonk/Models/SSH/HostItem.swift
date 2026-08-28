import Foundation
import os.log
import SwiftData

/// Authentication method for SSH connections.
enum AuthType: String, Codable {
    case password
    case privateKey
    case certificate
    case secureEnclave
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
    /// Sort order within group (used by drag-to-reorder).
    var sortOrder: Int = 0
    var isFavorite: Bool = false
    /// True when this entry is a serial port host (nil = SSH host).
    var isSerial: Bool?
    /// Baud rate for serial hosts; ignored for SSH hosts.
    var serialBaudRate: Int?

    @Relationship(deleteRule: .nullify)
    var groupRef: HostGroup?
    @Relationship(deleteRule: .nullify)
    var credentialRef: Credential?
    @Relationship(deleteRule: .nullify)
    var jumpHostRef: JumpHost?
    /// VNext — manual override: always use Compatibility engine (§6.4 forcedCompatibility)
    var forceCompatibility: Bool?
    /// Log coloring profile per-host (optional, additive, nil = use default)
    @Relationship(deleteRule: .nullify)
    var logProfile: LogProfile?

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

    // MARK: - Certificate credentials

    func loadCertificate() -> String? {
        KeychainHelper.get(for: KeychainHelper.certificateKey(for: id))
    }

    func storeCertificate(_ pem: String) {
        guard !pem.isEmpty else { return }
        KeychainHelper.set(pem, for: KeychainHelper.certificateKey(for: id))
    }

    // MARK: - Secure Enclave credentials

    func loadSecureEnclaveKeyTag() -> String? {
        KeychainHelper.get(for: KeychainHelper.secureEnclaveKey(for: id))
    }

    func storeSecureEnclaveKeyTag(_ tag: String) {
        guard !tag.isEmpty else { return }
        KeychainHelper.set(tag, for: KeychainHelper.secureEnclaveKey(for: id))
    }

    init(
        name: String,
        host: String,
        port: Int = SSHConstants.defaultPort,
        username: String,
        authType: AuthType = .password,
        password: String? = nil,
        privateKeyPEM: String? = nil,
        certificatePEM: String? = nil,
        secureEnclaveKeyTag: String? = nil,
        groupRef: HostGroup? = nil,
        credentialRef: Credential? = nil,
        jumpHostRef: JumpHost? = nil,
        isSerial: Bool? = nil,
        serialBaudRate: Int? = nil
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
        self.jumpHostRef = jumpHostRef
        self.isSerial = isSerial
        self.serialBaudRate = serialBaudRate

        if let passwordValue = password { storePassword(passwordValue) }
        if let pem = privateKeyPEM { storePrivateKey(pem) }
        if let cert = certificatePEM { storeCertificate(cert) }
        if let keyTag = secureEnclaveKeyTag { storeSecureEnclaveKeyTag(keyTag) }
    }

    func deleteCredentials() {
        KeychainHelper.delete(for: KeychainHelper.passwordKey(for: id))
        KeychainHelper.delete(for: KeychainHelper.privateKeyKey(for: id))
        KeychainHelper.delete(for: KeychainHelper.certificateKey(for: id))
    }

    /// Refresh the saved password after the user typed a working one into
    /// the terminal. Updates the vault credential when one is bound,
    /// otherwise the host-embedded Keychain entry.
    ///
    /// Private-key credentials are never overwritten — the password is saved
    /// to the host's own password entry instead, so it survives without
    /// destroying the key material.
    func updateSavedPassword(_ newPassword: String) {
        guard !newPassword.isEmpty else { return }
        if let cred = credentialRef, cred.type == .password {
            cred.storeSecret(newPassword)
            Log.session.info("[CRED] Updated vault credential \(cred.name, privacy: .public) password")
        } else {
            KeychainHelper.set(newPassword, for: KeychainHelper.passwordKey(for: id))
            if let cred = credentialRef, cred.type == .privateKey {
                Log.session.warning("[CRED] Saved typed password to host entry (vault credential \(cred.name, privacy: .public) is private-key type, left untouched)")
            } else {
                Log.session.info("[CRED] Updated host-embedded password for \(self.host, privacy: .public)")
            }
        }
    }

    /// Resolve the effective username.
    func resolveUsername() -> String {
        if let cred = credentialRef,
           let credUsername = cred.username, !credUsername.isEmpty
        {
            return credUsername
        }
        return username
    }

    /// Resolve the effective SSH auth method.
    func resolveAuthMethod() -> SSHAuthMethod? {
        // 1. Try vault credential
        if let cred = credentialRef,
           let secret = cred.loadSecret(), !secret.isEmpty
        {
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
        case .certificate:
            guard let pem = loadPrivateKey(), !pem.isEmpty else { return nil }
            let cert = loadCertificate() ?? ""
            return .certificate(privateKeyPEM: pem, certificatePEM: cert)
        case .secureEnclave:
            guard let keyTag = loadSecureEnclaveKeyTag(), !keyTag.isEmpty else { return nil }
            return .secureEnclaveKey(keyTag: keyTag)
        }
    }
}
