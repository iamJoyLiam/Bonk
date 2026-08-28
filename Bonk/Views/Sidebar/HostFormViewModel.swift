import Foundation
import SwiftData
import Observation

/// Elegant form model for Add / Edit Host.
/// - Single source of truth for UI state, independent of Keychain.
/// - Preserves custom credentials when switching to vault and back (往返不丢).
/// - Never deletes embedded Keychain entries unconditionally; only overwrites current type.
@Observable
final class HostFormViewModel {
    // MARK: - Form fields (UI state)

    var name = ""
    var host = ""
    var port = ""
    var username = ""
    var authType: AuthType = .password
    var password = ""
    var privateKeyPEM = ""
    var certificatePEM = ""
    var useFilePickerForKey = false
    var useFilePickerForCert = false
    var privateKeyFileURL: URL?
    var certificateFileURL: URL?
    var group = ""
    var selectedCredential: Credential?
    var showJumpHost = false
    var selectedJumpHost: JumpHost?
    var forceCompatibilityToggle = false
    var selectedLogProfile: LogProfile?

    // Secure Enclave
    var secureEnclaveKeyTag: String?
    var secureEnclaveKeyTagInput = ""
    var showSecureEnclaveGenerator = false
    var secureEnclaveKeyExists: Bool?
    var secureEnclaveVerificationMessage: String?

    // MARK: - Preservation

    private var lastCustomAuthType: AuthType = .password
    private var customPasswordBackup = ""
    private var customPrivateKeyBackup = ""
    private var customCertificateBackup = ""

    // MARK: - Context

    let existingHost: HostItem?
    let defaultPort: Int
    let initialHost: String?

    init(existingHost: HostItem? = nil, defaultPort: Int = 22, initialHost: String? = nil) {
        self.existingHost = existingHost
        self.defaultPort = defaultPort
        self.initialHost = initialHost
        load()
    }

    private func load() {
        guard let existing = existingHost else {
            port = String(defaultPort)
            if let initialHost {
                let parsed = SSHHostParser.parse(initialHost)
                let displayHost = parsed.host.isEmpty ? initialHost : parsed.host
                name = displayHost
                host = displayHost
                username = parsed.username ?? ""
                if let parsedPort = parsed.port { port = String(parsedPort) }
            }
            return
        }
        name = existing.name
        host = existing.host
        port = String(existing.port)
        username = existing.username
        authType = existing.authType
        lastCustomAuthType = existing.authType
        password = existing.loadPassword() ?? ""
        customPasswordBackup = password
        privateKeyPEM = existing.loadPrivateKey() ?? ""
        customPrivateKeyBackup = privateKeyPEM
        certificatePEM = existing.loadCertificate() ?? ""
        customCertificateBackup = certificatePEM
        secureEnclaveKeyTag = existing.loadSecureEnclaveKeyTag()
        secureEnclaveKeyTagInput = existing.loadSecureEnclaveKeyTag() ?? ""
        group = existing.groupRef?.name ?? ""
        selectedCredential = existing.credentialRef
        selectedJumpHost = existing.jumpHostRef
        showJumpHost = existing.jumpHostRef != nil
        forceCompatibilityToggle = existing.forceCompatibility == true
        selectedLogProfile = existing.logProfile

        // If editing a vault-backed host, keep custom fields as backup (already loaded)
        // so toggling back to custom restores them.
        if selectedCredential != nil {
            // Remember current custom authType for restore
            lastCustomAuthType = authType
        }
    }

    // MARK: - Derived

    var usingVault: Bool { selectedCredential != nil }

    var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let hasName = !trimmedName.isEmpty
        let hasHost = !trimmedHost.isEmpty || hasName
        let hasUser = !trimmedUser.isEmpty || (usingVault && selectedCredential?.username?.isEmpty == false)
        let hasCred: Bool = {
            if usingVault { return true }
            switch authType {
            case .password: return !password.isEmpty
            case .privateKey: return !privateKeyPEM.isEmpty
            case .certificate: return !privateKeyPEM.isEmpty && !certificatePEM.isEmpty
            case .secureEnclave: return !(secureEnclaveKeyTag ?? "").isEmpty
            }
        }()
        return hasName && hasHost && hasUser && hasCred
    }

    // MARK: - Vault <-> Custom transition (elegant preservation)

    func onCredentialChanged(_ newCred: Credential?) {
        if let cred = newCred {
            // Switching to vault: backup custom state
            customPasswordBackup = password
            customPrivateKeyBackup = privateKeyPEM
            customCertificateBackup = certificatePEM
            lastCustomAuthType = authType
            authType = cred.type == .privateKey ? .privateKey : .password
        } else {
            // Switching back to custom: restore
            password = customPasswordBackup
            privateKeyPEM = customPrivateKeyBackup
            certificatePEM = customCertificateBackup
            authType = lastCustomAuthType
            // If backup was empty but host had embedded, it will be restored from load (already in state)
        }
    }

    // MARK: - Secure Enclave

    func verifySecureEnclaveKey(i18n: I18n) {
        let tagToVerify = secureEnclaveKeyTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagToVerify.isEmpty else {
            secureEnclaveKeyExists = false
            secureEnclaveVerificationMessage = i18n.t(.enterKeyIdentifier)
            return
        }
        let exists = SecureEnclaveKeyManager.keyExists(tag: tagToVerify)
        if exists { secureEnclaveKeyTag = tagToVerify }
        secureEnclaveKeyExists = exists
        secureEnclaveVerificationMessage = exists ? i18n.t(.keyVerified) : i18n.t(.keyNotFound)
    }

    // MARK: - Save (elegant Keychain semantics)

    /// Saves to the given HostItem or creates a new one. Never deletes embedded credentials unconditionally.
    func save(hostGroups: [HostGroup], modelContext: ModelContext, onSave: (HostItem) -> Void, i18n: I18n) {
        let portNum = Int(port) ?? defaultPort
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let hostInput = host.trimmingCharacters(in: .whitespaces)
        let parsedHost = SSHHostParser.parse(hostInput.isEmpty ? trimmedName : hostInput)
        let trimmedHost = parsedHost.host.isEmpty ? (hostInput.isEmpty ? trimmedName : hostInput) : parsedHost.host
        let trimmedUser = username.trimmingCharacters(in: .whitespaces).isEmpty ? (parsedHost.username ?? "") : username.trimmingCharacters(in: .whitespaces)
        let effectivePort = parsedHost.port ?? portNum
        let trimmedGroup = group.isEmpty ? nil : group.trimmingCharacters(in: .whitespaces)
        let groupRef: HostGroup? = {
            guard let trimmedGroup else { return nil }
            return hostGroups.first(where: { $0.name == trimmedGroup })
        }()

        if let existing = existingHost {
            existing.name = trimmedName
            existing.host = trimmedHost
            existing.port = effectivePort
            existing.username = trimmedUser
            existing.authType = authType
            existing.credentialRef = selectedCredential
            existing.jumpHostRef = showJumpHost ? selectedJumpHost : nil
            existing.groupRef = groupRef
            existing.logProfile = selectedLogProfile

            // Elegant: only overwrite the current authType's Keychain entry, never delete all.
            // Embedded credentials remain as backup when using vault.
            if !usingVault {
                switch authType {
                case .password:
                    if !password.isEmpty { existing.storePassword(password) }
                case .privateKey:
                    if !privateKeyPEM.isEmpty { existing.storePrivateKey(privateKeyPEM) }
                case .certificate:
                    if !privateKeyPEM.isEmpty { existing.storePrivateKey(privateKeyPEM) }
                    if !certificatePEM.isEmpty { existing.storeCertificate(certificatePEM) }
                case .secureEnclave:
                    if let keyTag = secureEnclaveKeyTag, !keyTag.isEmpty { existing.storeSecureEnclaveKeyTag(keyTag) }
                }
            }
            // When using vault, keep embedded as backup; do not delete.
            onSave(existing)
        } else {
            let item = HostItem(
                name: trimmedName,
                host: trimmedHost,
                port: effectivePort,
                username: trimmedUser,
                authType: authType,
                password: usingVault ? nil : (authType == .password ? password : nil),
                privateKeyPEM: usingVault ? nil : (authType != .password && authType != .secureEnclave ? privateKeyPEM : nil),
                certificatePEM: usingVault ? nil : (authType == .certificate ? certificatePEM : nil),
                secureEnclaveKeyTag: usingVault ? nil : (authType == .secureEnclave ? secureEnclaveKeyTag : nil),
                groupRef: groupRef,
                credentialRef: selectedCredential,
                jumpHostRef: showJumpHost ? selectedJumpHost : nil
            )
            if forceCompatibilityToggle { item.forceCompatibility = true }
            item.logProfile = selectedLogProfile
            onSave(item)
        }
    }
}
