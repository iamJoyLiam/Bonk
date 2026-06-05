import SwiftUI
import SwiftData

struct AddHostSheet: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Credential.createdAt, order: .reverse) private var vaultCredentials: [Credential]
    @Query(sort: \HostGroup.sortOrder) private var hostGroups: [HostGroup]
    @Query private var allPreferences: [UserPreferences]

    let existingHost: HostItem?
    let defaultPort: Int
    let onSave: (HostItem) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var authType: AuthType = .password
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @State private var group = ""
    @State private var showPassword = false
    @State private var showGroupDropdown = false
    @State private var selectedCredentialID: String?

    init(existingHost: HostItem? = nil, defaultPort: Int = 22, onSave: @escaping (HostItem) -> Void) {
        self.existingHost = existingHost
        self.defaultPort = defaultPort
        self.onSave = onSave
    }

    // MARK: - Computed

    private var usingVault: Bool { selectedCredentialID != nil }

    private var matchingCredentials: [Credential] {
        vaultCredentials.filter { $0.type == .password || $0.type == .privateKey }
    }

    private var groupExists: Bool {
        let q = group.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && hostGroups.contains(where: { $0.name.lowercased() == q.lowercased() })
    }

    private var selectedGroup: HostGroup? {
        hostGroups.first(where: { $0.name == group })
    }

    private var isValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasHost = !host.trimmingCharacters(in: .whitespaces).isEmpty || hasName
        let hasUser = !username.trimmingCharacters(in: .whitespaces).isEmpty
            || (usingVault && vaultCredential?.username?.isEmpty == false)
        let hasCred = usingVault || (authType == .password ? !password.isEmpty : !privateKeyPEM.isEmpty)
        return hasName && hasHost && hasUser && hasCred
    }

    private var vaultCredential: Credential? {
        selectedCredentialID.flatMap { id in matchingCredentials.first(where: { $0.name == id }) }
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section(i18n.t(.hostInformation)) {
                TextField(i18n.t(.displayName), text: $name)
                TextField(i18n.t(.hostnameOrIp), text: $host, prompt: Text(name.isEmpty ? "" : name))
                    .textContentType(.URL).autocorrectionDisabled()
                TextField(i18n.t(.port), text: $port)
                TextField(i18n.t(.username), text: $username).autocorrectionDisabled()
                groupComboBox
            }

            Section(i18n.t(.authentication)) {
                Picker(i18n.t(.credential), selection: $selectedCredentialID) {
                    Text(i18n.t(.custom)).tag(String?.none)
                    ForEach(matchingCredentials, id: \.self) { cred in
                        Label(cred.name, systemImage: cred.type.symbolName).tag(String?.some(cred.name))
                    }
                }
                .onChange(of: selectedCredentialID) { _, newID in
                    if let cred = newID.flatMap({ id in vaultCredentials.first(where: { $0.name == id }) }) {
                        authType = cred.type == .privateKey ? .privateKey : .password
                    }
                }

                if !usingVault {
                    Picker(i18n.t(.method), selection: $authType) {
                        Text(i18n.t(.password)).tag(AuthType.password)
                        Text(i18n.t(.privateKey)).tag(AuthType.privateKey)
                    }
                    .pickerStyle(.segmented)

                    switch authType {
                    case .password:
                        HStack {
                            if showPassword { TextField(i18n.t(.password), text: $password) }
                            else { SecureField(i18n.t(.password), text: $password) }
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    case .privateKey:
                        Text(i18n.t(.pastePemKey)).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $privateKeyPEM)
                            .font(.system(.caption, design: .monospaced)).frame(minHeight: 120)
                    }
                } else if let cred = vaultCredential {
                    LabeledContent(i18n.t(.credential)) {
                        Label(cred.name, systemImage: cred.type.symbolName)
                    }
                    if let u = cred.username, !u.isEmpty {
                        LabeledContent(i18n.t(.username)) { Text(u) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 480)
        .navigationTitle(existingHost == nil ? i18n.t(.addHost) : i18n.t(.editHost))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(i18n.t(.cancel)) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) { save() }
                    .disabled(!isValid).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { loadExisting() }
    }

    // MARK: - Group Combo Box

    private var groupComboBox: some View {
        HStack(spacing: 6) {
            TextField(i18n.t(.groupOptional), text: $group)
                .autocorrectionDisabled()
                .onSubmit { commitGroup() }

            // Color + icon after text field
            if let g = selectedGroup, !group.isEmpty {
                GroupIndicator(group: g)
            }

            if !group.isEmpty {
                Button { group = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button { showGroupDropdown.toggle() } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showGroupDropdown, arrowEdge: .bottom) {
                groupDropdown.fixedSize()
            }
        }
    }

    private var groupDropdown: some View {
        let input = group.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 0) {
            if hostGroups.isEmpty && input.isEmpty {
                Text(i18n.t(.noGroups)).font(.caption).foregroundStyle(.tertiary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hostGroups) { g in
                            groupRow(g)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if !input.isEmpty && !groupExists {
                Divider()
                Button { commitGroup(); showGroupDropdown = false } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        Text(input).font(.system(size: 12)).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func groupRow(_ g: HostGroup) -> some View {
        Button { group = g.name; showGroupDropdown = false } label: {
            HStack(spacing: 6) {
                GroupIndicator(group: g)
                Text(g.name).font(.system(size: 12)).lineLimit(1)
                if g.name == group {
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func commitGroup() {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !groupExists else { return }
        modelContext.insert(HostGroup(name: trimmed))
    }

    // MARK: - Actions

    private func loadExisting() {
        guard let h = existingHost else { port = String(defaultPort); return }
        name = h.name; host = h.host; port = String(h.port); username = h.username
        authType = h.authType; password = h.loadPassword() ?? ""; privateKeyPEM = h.loadPrivateKey() ?? ""
        group = h.group ?? ""; selectedCredentialID = h.credentialID
    }

    private func save() {
        let portNum = Int(port) ?? defaultPort
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedName : host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedGroup = group.isEmpty ? nil : group.trimmingCharacters(in: .whitespaces)

        if let existing = existingHost {
            existing.name = trimmedName; existing.host = trimmedHost; existing.port = portNum
            existing.username = trimmedUser; existing.authType = authType; existing.credentialID = selectedCredentialID
            existing.deleteCredentials()
            if !usingVault {
                if authType == .password { existing.storePassword(password) }
                else { existing.storePrivateKey(privateKeyPEM) }
            }
            existing.group = trimmedGroup
            onSave(existing)
        } else {
            let item = HostItem(
                name: trimmedName, host: trimmedHost, port: portNum, username: trimmedUser,
                authType: authType,
                password: usingVault ? nil : (authType == .password ? password : nil),
                privateKeyPEM: usingVault ? nil : (authType == .privateKey ? privateKeyPEM : nil),
                group: trimmedGroup, credentialID: selectedCredentialID
            )
            onSave(item)
        }
        dismiss()
    }
}

// MARK: - Shared Indicator

/// Small color dot + icon, used in combo box, dropdown, and sidebar.
struct GroupIndicator: View {
    let group: HostGroup

    var body: some View {
        HStack(spacing: 4) {
            if let color = group.resolvedColor {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            if let icon = group.icon, !icon.isEmpty {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
