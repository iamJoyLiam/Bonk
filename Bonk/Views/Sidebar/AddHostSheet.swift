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
    @State private var showPassword = false
    @State private var selectedCredential: Credential?
    @State private var jumpHostHostname = ""
    @State private var jumpHostPort = "22"
    @State private var jumpHostUsername = ""
    @State private var showJumpHost = false

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
                        HStack {
                            if showPassword {
                                TextField(
                                    i18n.t(.password),
                                    text: $password
                                )
                            } else {
                                SecureField(
                                    i18n.t(.password),
                                    text: $password
                                )
                            }
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword
                                    ? "eye.slash"
                                    : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    case .privateKey:
                        Text(i18n.t(.pastePemKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $privateKeyPEM)
                            .font(.system(
                                .caption,
                                design: .monospaced
                            ))
                            .frame(minHeight: 120)
                        if let type = detectedPrivateKeyType {
                            Text(i18n.tr(.detectedKeyType, args: type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                            filePickerField(
                                url: $privateKeyFileURL,
                                content: $privateKeyPEM,
                                placeholder: i18n.t(.selectPrivateKeyFile)
                            )
                        } else {
                            Text(i18n.t(.pastePemKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $privateKeyPEM)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 100)
                            if let type = detectedPrivateKeyType {
                                Text(i18n.tr(.detectedKeyType, args: type))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                            filePickerField(
                                url: $certificateFileURL,
                                content: $certificatePEM,
                                placeholder: i18n.t(.selectCertificateFile)
                            )
                        } else {
                            Text(i18n.t(.pasteCertificate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $certificatePEM)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 100)
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
                                    .padding(8)
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
                    TextField(i18n.t(.jumpHostHostname), text: $jumpHostHostname)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    TextField(i18n.t(.port), text: $jumpHostPort)
                        .font(.system(size: 13, design: .monospaced))
                    TextField(i18n.t(.username), text: $jumpHostUsername)
                        .autocorrectionDisabled()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 480)
        .navigationTitle(
            existingHost == nil
                ? i18n.t(.addHost)
                : i18n.t(.editHost)
        )
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
                name = initialHost
                host = initialHost
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
    }

    private func save() {
        let portNum = Int(port) ?? defaultPort
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let hostInput = host.trimmingCharacters(in: .whitespaces)
        let trimmedHost = hostInput.isEmpty ? trimmedName : hostInput
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
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
            existing.port = portNum
            existing.username = trimmedUser
            existing.authType = authType
            existing.credentialRef = selectedCredential
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
                port: portNum,
                username: trimmedUser,
                authType: authType,
                password: usingVault ? nil : (authType == .password ? password : nil),
                privateKeyPEM: usingVault ? nil : (authType != .password ? privateKeyPEM : nil),
                certificatePEM: usingVault ? nil : (authType == .certificate ? certificatePEM : nil),
                secureEnclaveKeyTag: usingVault ? nil : (authType == .secureEnclave ? secureEnclaveKeyTag : nil),
                groupRef: groupRef,
                credentialRef: selectedCredential
            )
            onSave(item)
        }
        dismiss()
    }

    // MARK: - File Picker Field

    @ViewBuilder
    private func filePickerField(
        url: Binding<URL?>,
        content: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fileURL = url.wrappedValue {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.blue)
                    Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        url.wrappedValue = nil
                        content.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .cornerRadius(6)
            } else {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.item]

                    if panel.runModal() == .OK, let selectedURL = panel.url {
                        url.wrappedValue = selectedURL
                        // Read file content
                        if let data = try? Data(contentsOf: selectedURL),
                           let text = String(data: data, encoding: .utf8)
                        {
                            content.wrappedValue = text
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(placeholder)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
    }

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
