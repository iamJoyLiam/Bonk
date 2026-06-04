import SwiftUI
import SwiftData

/// Sheet for creating or editing an SSH host configuration.
struct AddHostSheet: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Credential.createdAt, order: .reverse) private var vaultCredentials: [Credential]
    @Query private var allPreferences: [UserPreferences]

    let existingHost: HostItem?
    let defaultPort: Int
    let onSave: (HostItem) -> Void

    private var preferences: UserPreferences {
        allPreferences.first ?? UserPreferences()
    }

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var username: String = ""
    @State private var authType: AuthType = .password
    @State private var password: String = ""
    @State private var privateKeyPEM: String = ""
    @State private var group: String = ""
    @State private var showPassword: Bool = false
    /// nil = custom (inline fields), non-nil = vault credential ID
    @State private var selectedCredentialID: String?

    init(
        existingHost: HostItem? = nil,
        defaultPort: Int = 22,
        onSave: @escaping (HostItem) -> Void
    ) {
        self.existingHost = existingHost
        self.defaultPort = defaultPort
        self.onSave = onSave
    }

    private var usingVault: Bool { selectedCredentialID != nil }

    private var matchingCredentials: [Credential] {
        vaultCredentials.filter { $0.type == .password || $0.type == .privateKey }
    }

    var body: some View {
        Form {
            Section(i18n.t(.hostInformation)) {
                TextField(i18n.t(.displayName), text: $name)

                TextField(i18n.t(.hostnameOrIp), text: $host, prompt: Text(name.isEmpty ? "" : name))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField(i18n.t(.port), text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                TextField(i18n.t(.username), text: $username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField(i18n.t(.groupOptional), text: $group)
            }

            Section(i18n.t(.authentication)) {
                // Credential source picker
                Picker(i18n.t(.credential), selection: $selectedCredentialID) {
                    Text(i18n.t(.custom)).tag(String?.none)
                    ForEach(matchingCredentials, id: \.self) { cred in
                        Label(cred.name, systemImage: cred.type.symbolName)
                            .tag(String?.some(cred.name))
                    }
                }
                .onChange(of: selectedCredentialID) { _, newID in
                    // Auto-set authType from vault credential
                    if let id = newID,
                       let cred = vaultCredentials.first(where: { $0.name == id }) {
                        authType = cred.type == .privateKey ? .privateKey : .password
                    }
                }

                if !usingVault {
                    // Inline credential fields (custom mode)
                    Picker(i18n.t(.method), selection: $authType) {
                        Text(i18n.t(.password)).tag(AuthType.password)
                        Text(i18n.t(.privateKey)).tag(AuthType.privateKey)
                    }
                    .pickerStyle(.segmented)

                    switch authType {
                    case .password:
                        HStack {
                            if showPassword {
                                TextField(i18n.t(.password), text: $password)
                            } else {
                                SecureField(i18n.t(.password), text: $password)
                            }
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                    case .privateKey:
                        Text(i18n.t(.pastePemKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $privateKeyPEM)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                    }
                } else {
                    // Show vault credential info
                    if let id = selectedCredentialID,
                       let cred = vaultCredentials.first(where: { $0.name == id }) {
                        LabeledContent(i18n.t(.credential)) {
                            Label(cred.name, systemImage: cred.type.symbolName)
                        }
                        if let u = cred.username, !u.isEmpty {
                            LabeledContent(i18n.t(.username)) {
                                Text(u)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 480)
        .navigationTitle(existingHost == nil ? i18n.t(.addHost) : i18n.t(.editHost))
        #if os(macOS)
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
        #else
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(i18n.t(.cancel)) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) { save() }
                    .disabled(!isValid)
            }
        }
        #endif
        .onAppear { loadExisting() }
    }

    private var isValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasHost = !host.trimmingCharacters(in: .whitespaces).isEmpty || !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasUsername = !username.trimmingCharacters(in: .whitespaces).isEmpty
            || (usingVault && vaultCredential?.username?.isEmpty == false)
        let hasCredential = usingVault || (authType == .password ? !password.isEmpty : !privateKeyPEM.isEmpty)
        return hasName && hasHost && hasUsername && hasCredential
    }

    private var vaultCredential: Credential? {
        guard let id = selectedCredentialID else { return nil }
        return matchingCredentials.first(where: { $0.name == id })
    }

    private func loadExisting() {
        guard let h = existingHost else {
            port = String(defaultPort)
            return
        }
        name = h.name
        host = h.host
        port = String(h.port)
        username = h.username
        authType = h.authType
        password = h.loadPassword() ?? ""
        privateKeyPEM = h.loadPrivateKey() ?? ""
        group = h.group ?? ""
        selectedCredentialID = h.credentialID
    }

    private func save() {
        let portNum = Int(port) ?? defaultPort
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedName : host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedGroup = group.isEmpty ? nil : group.trimmingCharacters(in: .whitespaces)

        if let existing = existingHost {
            existing.name = trimmedName
            existing.host = trimmedHost
            existing.port = portNum
            existing.username = trimmedUser
            existing.authType = authType
            existing.credentialID = selectedCredentialID
            existing.deleteCredentials() // Clear old keychain entries
            if !usingVault {
                if authType == .password { existing.storePassword(password) }
                else { existing.storePrivateKey(privateKeyPEM) }
            }
            existing.group = trimmedGroup
            onSave(existing)
        } else {
            let item = HostItem(
                name: trimmedName,
                host: trimmedHost,
                port: portNum,
                username: trimmedUser,
                authType: authType,
                password: usingVault ? nil : (authType == .password ? password : nil),
                privateKeyPEM: usingVault ? nil : (authType == .privateKey ? privateKeyPEM : nil),
                group: trimmedGroup,
                credentialID: selectedCredentialID
            )
            onSave(item)
        }
        dismiss()
    }
}
