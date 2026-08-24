import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import Citadel

struct AddHostSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Credential.createdAt, order: .reverse)
    private var vaultCredentials: [Credential]
    @Query(sort: \HostGroup.sortOrder)
    private var hostGroups: [HostGroup]
    @Query(sort: \JumpHost.sortOrder)
    private var jumpHosts: [JumpHost]

    let existingHost: HostItem?
    let defaultPort: Int
    let initialHost: String?
    let onSave: (HostItem) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var authType: AuthType = .password
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @State private var certificatePEM = ""
    @State private var useFilePickerForKey = false
    @State private var useFilePickerForCert = false
    @State private var privateKeyFileURL: URL?
    @State private var certificateFileURL: URL?
    @State private var group = ""
    @State private var selectedCredential: Credential?
    @State private var showJumpHost = false
    @State private var selectedJumpHost: JumpHost?
    @State private var forceCompatibilityToggle = false

    /// Detected key algorithm (Citadel 0.11+) for the pasted private key.
    private var detectedPrivateKeyType: String? {
        let trimmed = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? SSHKeyDetection.detectPrivateKeyType(from: trimmed))?.description
    }

    // Secure Enclave state
    @State private var secureEnclaveKeyTag: String?
    @State private var secureEnclaveKeyTagInput: String = ""
    @State private var showSecureEnclaveGenerator = false
    @State private var secureEnclaveKeyExists: Bool?
    @State private var secureEnclaveVerificationMessage: String?

    init(
        existingHost: HostItem? = nil,
        defaultPort: Int = 22,
        initialHost: String? = nil,
        onSave: @escaping (HostItem) -> Void
    ) {
        self.existingHost = existingHost
        self.defaultPort = defaultPort
        self.initialHost = initialHost
        self.onSave = onSave
    }

    // MARK: - Computed

    private var usingVault: Bool {
        selectedCredential != nil
    }

    private var matchingCredentials: [Credential] {
        vaultCredentials.filter {
            $0.type == .password || $0.type == .privateKey
        }
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let hasName = !trimmedName.isEmpty
        let hasHost = !trimmedHost.isEmpty || hasName
        let hasUser = !trimmedUser.isEmpty
            || (usingVault && selectedCredential?.username?.isEmpty == false)
        let hasCred = usingVault
            || (authType == .password
                ? !password.isEmpty
                : authType == .certificate
                    ? !privateKeyPEM.isEmpty && !certificatePEM.isEmpty
                    : !privateKeyPEM.isEmpty)
        return hasName && hasHost && hasUser && hasCred
    }

    private var vaultCredential: Credential? {
        selectedCredential
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppStyle.spacingM) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                Text(existingHost == nil ? i18n.t(.addHost) : i18n.t(.editHost))
                    .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            Divider()
            Form {
                Section(i18n.t(.hostInformation)) {
                TextField(i18n.t(.displayName), text: $name)
                TextField(
                    i18n.t(.hostnameOrIp),
                    text: $host,
                    prompt: Text(name.isEmpty ? "" : name)
                )
                .textContentType(.URL)
                .autocorrectionDisabled()
                TextField(i18n.t(.port), text: $port)
                TextField(i18n.t(.username), text: $username)
                    .autocorrectionDisabled()
                GroupComboBoxView(group: $group)
            }

            Section(i18n.t(.authentication)) {
                Picker(
                    i18n.t(.credential),
                    selection: $selectedCredential
                ) {
                    Text(i18n.t(.custom)).tag(Credential?.none)
                    ForEach(matchingCredentials, id: \.self) { cred in
                        Label(
                            cred.name,
                            systemImage: cred.type.symbolName
                        )
                        .tag(Credential?.some(cred))
                    }
                }
                .onChange(of: selectedCredential) { _, newCred in
                    if let cred = newCred {
                        authType = cred.type == .privateKey
                            ? .privateKey
                            : .password
                    }
                }

                if !usingVault {
                    Picker(i18n.t(.method), selection: $authType) {
                        Text(i18n.t(.password))
                            .tag(AuthType.password)
                        Text(i18n.t(.privateKey))
                            .tag(AuthType.privateKey)
                        Text(i18n.t(.certificate))
                            .tag(AuthType.certificate)
                        Text(i18n.t(.secureEnclave))
                            .tag(AuthType.secureEnclave)
                    }
                    .pickerStyle(.segmented)

                    switch authType {
                    case .password:
                        LabeledSecureField(title: i18n.t(.password), text: $password)
                    case .privateKey:
                        PEMEditorField(
                            text: $privateKeyPEM,
                            detectedType: detectedPrivateKeyType.map { i18n.tr(.detectedKeyType, args: $0) },
                            hint: i18n.t(.pastePemKey)
                        )
                    case .certificate:
                        // Private Key
                        HStack {
                            Text(i18n.t(.privateKey))
                                .font(.headline)
                            Spacer()
                            Button(useFilePickerForKey ? i18n.t(.pasteManually) : i18n.t(.selectFile)) {
                                useFilePickerForKey.toggle()
                            }
                            .font(.caption)
                        }

                        if useFilePickerForKey {
                            FilePickerCard(
                                url: $privateKeyFileURL,
                                content: $privateKeyPEM,
                                placeholder: i18n.t(.selectPrivateKeyFile)
                            )
                        } else {
                            PEMEditorField(
                                text: $privateKeyPEM,
                                minHeight: 100,
                                detectedType: detectedPrivateKeyType.map { i18n.tr(.detectedKeyType, args: $0) },
                                hint: i18n.t(.pastePemKey)
                            )
                        }

                        // Certificate
                        HStack {
                            Text(i18n.t(.certificate))
                                .font(.headline)
                            Spacer()
                            Button(useFilePickerForCert ? i18n.t(.pasteManually) : i18n.t(.selectFile)) {
                                useFilePickerForCert.toggle()
                            }
                            .font(.caption)
                        }

                        if useFilePickerForCert {
                            FilePickerCard(
                                url: $certificateFileURL,
                                content: $certificatePEM,
                                placeholder: i18n.t(.selectCertificateFile)
                            )
                        } else {
                            PEMEditorField(
                                text: $certificatePEM,
                                minHeight: 100,
                                hint: i18n.t(.pasteCertificate)
                            )
                        }
                    case .secureEnclave:
                        VStack(alignment: .leading, spacing: 12) {
                            Text(i18n.t(.hardwareProtectionDesc))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let selectedTag = secureEnclaveKeyTag, !selectedTag.isEmpty {
                                // Show selected key info
                                GroupBox {
                                    HStack {
                                        Image(systemName: "lock.shield.fill")
                                            .foregroundStyle(.green)
                                        VStack(alignment: .leading) {
                                            Text(selectedTag)
                                                .font(.headline)
                                            Text(i18n.t(.secureEnclave))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(i18n.t(.change)) {
                                            secureEnclaveKeyTag = nil
                                            secureEnclaveKeyTagInput = ""
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(AppStyle.spacingM)
                                }
                            } else {
                                // Key selection
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(i18n.t(.keyIdentifierHint))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    TextField(i18n.t(.exampleKeyTag), text: $secureEnclaveKeyTagInput)
                                        .textFieldStyle(.roundedBorder)

                                    HStack {
                                        Button(i18n.t(.verifyKey)) {
                                            verifySecureEnclaveKey()
                                        }
                                        .disabled(secureEnclaveKeyTagInput.isEmpty)

                                        if let verificationMessage = secureEnclaveVerificationMessage {
                                            Text(verificationMessage)
                                                .font(.caption)
                                                .foregroundStyle((secureEnclaveKeyExists ?? false) ? .green : .red)
                                        }
                                    }

                                    Divider()

                                    Button(i18n.t(.generateSecureEnclaveKey)) {
                                        showSecureEnclaveGenerator = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                } else if let cred = vaultCredential {
                    LabeledContent(i18n.t(.credential)) {
                        Label(
                            cred.name,
                            systemImage: cred.type.symbolName
                        )
                    }
                    if let credUsername = cred.username,
                       !credUsername.isEmpty
                    {
                        LabeledContent(i18n.t(.username)) {
                            Text(credUsername)
                        }
                    }
                }
            }

            // Jump Host (advanced option)
            Section {
                Toggle(i18n.t(.jumpHostAdvanced), isOn: $showJumpHost)
                if showJumpHost {
                    Picker(i18n.t(.jumpHosts), selection: $selectedJumpHost) {
                        Text(i18n.t(.none)).tag(JumpHost?.none)
                        ForEach(jumpHosts) { jumpHost in
                            Text(jumpHost.displayString).tag(JumpHost?.some(jumpHost))
                        }
                    }
                    .disabled(jumpHosts.isEmpty)
                    if jumpHosts.isEmpty {
                        Text(i18n.t(.noJumpHosts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // VNext — SSH Engine diagnosis (§6.4)
            if let existing = existingHost {
                Section(i18n.t(.sshEngineDiagnosis)) {
                    HostConnectionDiagnosisView(host: existing)
                }
            } else {
                Section(i18n.t(.sshEngineDiagnosis)) {
                    Toggle(isOn: $forceCompatibilityToggle) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i18n.t(.sshAlwaysCompatibility))
                                .font(.system(size: AppStyle.fontBody, weight: .medium))
                            Text(i18n.t(.sshAlwaysCompatibilityDesc))
                                .font(.system(size: AppStyle.fontCaption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            }
            .formStyle(.grouped)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: AppStyle.panelWidthMedium)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(i18n.t(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) { save() }
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { loadExisting() }
        .sheet(isPresented: $showSecureEnclaveGenerator) {
            SecureEnclaveKeyGeneratorView()
                .environment(i18n)
                .onDisappear {
                    // Refresh verification after key generation
                    if let tag = secureEnclaveKeyTag, !tag.isEmpty {
                        verifySecureEnclaveKey()
                    }
                }
        }
    }

    // MARK: - Actions

    private func loadExisting() {
        guard let existing = existingHost else {
            port = String(defaultPort)
            // Pre-fill with initial host if provided
            if let initialHost {
                let parsed = SSHHostParser.parse(initialHost)
                let displayHost = parsed.host.isEmpty ? initialHost : parsed.host
                name = displayHost
                host = displayHost
                username = parsed.username ?? ""
                if let parsedPort = parsed.port {
                    port = String(parsedPort)
                }
            }
            return
        }
        name = existing.name
        host = existing.host
        port = String(existing.port)
        username = existing.username
        authType = existing.authType
        password = existing.loadPassword() ?? ""
        privateKeyPEM = existing.loadPrivateKey() ?? ""
        certificatePEM = existing.loadCertificate() ?? ""
        secureEnclaveKeyTag = existing.loadSecureEnclaveKeyTag()
        secureEnclaveKeyTagInput = existing.loadSecureEnclaveKeyTag() ?? ""
        group = existing.groupRef?.name ?? ""
        selectedCredential = existing.credentialRef
        selectedJumpHost = existing.jumpHostRef
        showJumpHost = existing.jumpHostRef != nil
        forceCompatibilityToggle = existing.forceCompatibility == true
    }

    private func save() {
        let portNum = Int(port) ?? defaultPort
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let hostInput = host.trimmingCharacters(in: .whitespaces)
        let parsedHost = SSHHostParser.parse(hostInput.isEmpty ? trimmedName : hostInput)
        let trimmedHost = parsedHost.host.isEmpty ? (hostInput.isEmpty ? trimmedName : hostInput) : parsedHost.host
        let trimmedUser = username.trimmingCharacters(in: .whitespaces).isEmpty
            ? (parsedHost.username ?? "")
            : username.trimmingCharacters(in: .whitespaces)
        let effectivePort = parsedHost.port ?? portNum
        let trimmedGroup = group.isEmpty
            ? nil
            : group.trimmingCharacters(in: .whitespaces)

        // Resolve group reference
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
            existing.deleteCredentials()
            if !usingVault {
                switch authType {
                case .password:
                    existing.storePassword(password)
                case .privateKey:
                    existing.storePrivateKey(privateKeyPEM)
                case .certificate:
                    existing.storePrivateKey(privateKeyPEM)
                    existing.storeCertificate(certificatePEM)
                case .secureEnclave:
                    if let keyTag = secureEnclaveKeyTag {
                        existing.storeSecureEnclaveKeyTag(keyTag)
                    }
                }
            }
            onSave(existing)
        } else {
            let item = HostItem(
                name: trimmedName,
                host: trimmedHost,
                port: effectivePort,
                username: trimmedUser,
                authType: authType,
                password: usingVault ? nil : (authType == .password ? password : nil),
                privateKeyPEM: usingVault ? nil : (authType != .password ? privateKeyPEM : nil),
                certificatePEM: usingVault ? nil : (authType == .certificate ? certificatePEM : nil),
                secureEnclaveKeyTag: usingVault ? nil : (authType == .secureEnclave ? secureEnclaveKeyTag : nil),
                groupRef: groupRef,
                credentialRef: selectedCredential,
                jumpHostRef: showJumpHost ? selectedJumpHost : nil
            )
            if forceCompatibilityToggle { item.forceCompatibility = true }
            onSave(item)
        }
        dismiss()
    }

    // FilePickerCard now lives in Bonk/Views/Common/BonkFormFields.swift

    // MARK: - Secure Enclave Helpers

    private func verifySecureEnclaveKey() {
        let tagToVerify = secureEnclaveKeyTagInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !tagToVerify.isEmpty else {
            secureEnclaveKeyExists = false
            secureEnclaveVerificationMessage = i18n.t(.enterKeyIdentifier)
            return
        }

        let exists = SecureEnclaveKeyManager.keyExists(tag: tagToVerify)

        if exists {
            secureEnclaveKeyTag = tagToVerify
        }
        secureEnclaveKeyExists = exists
        secureEnclaveVerificationMessage = exists ? i18n.t(.keyVerified) : i18n.t(.keyNotFound)
    }
}
