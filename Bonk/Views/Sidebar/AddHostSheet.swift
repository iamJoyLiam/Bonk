import SwiftData
import SwiftUI

struct AddHostSheet: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Credential.createdAt, order: .reverse)
    private var vaultCredentials: [Credential]
    @Query(sort: \HostGroup.sortOrder)
    private var hostGroups: [HostGroup]

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
    @State private var selectedCredential: Credential?
    @State private var jumpHostHostname = ""
    @State private var jumpHostPort = "22"
    @State private var jumpHostUsername = ""
    @State private var showJumpHost = false

    init(
        existingHost: HostItem? = nil,
        defaultPort: Int = 22,
        onSave: @escaping (HostItem) -> Void
    ) {
        self.existingHost = existingHost
        self.defaultPort = defaultPort
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

    private var groupExists: Bool {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return hostGroups.contains {
            $0.name.lowercased() == trimmed.lowercased()
        }
    }

    private var selectedGroup: HostGroup? {
        hostGroups.first(where: { $0.name == group })
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
                groupComboBox
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
    }

    // MARK: - Group Combo Box

    private var groupComboBox: some View {
        HStack(spacing: 6) {
            TextField(i18n.t(.groupOptional), text: $group)
                .autocorrectionDisabled()
                .onSubmit { commitGroup() }

            if let selected = selectedGroup, !group.isEmpty {
                GroupIndicator(group: selected)
            }

            if !group.isEmpty {
                Button { group = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button { showGroupDropdown.toggle() } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(
                isPresented: $showGroupDropdown,
                arrowEdge: .bottom
            ) {
                groupDropdown.fixedSize()
            }
        }
    }

    private var groupDropdown: some View {
        let input = group.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 0) {
            if hostGroups.isEmpty, input.isEmpty {
                Text(i18n.t(.noGroups))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hostGroups) { hostGroup in
                            groupRow(hostGroup)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if !input.isEmpty, !groupExists {
                Divider()
                Button {
                    commitGroup()
                    showGroupDropdown = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentColor)
                        Text(input)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func groupRow(_ hostGroup: HostGroup) -> some View {
        Button {
            group = hostGroup.name
            showGroupDropdown = false
        } label: {
            HStack(spacing: 6) {
                GroupIndicator(group: hostGroup)
                Text(hostGroup.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if hostGroup.name == group {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
        guard let existing = existingHost else {
            port = String(defaultPort)
            return
        }
        name = existing.name
        host = existing.host
        port = String(existing.port)
        username = existing.username
        authType = existing.authType
        password = existing.loadPassword() ?? ""
        privateKeyPEM = existing.loadPrivateKey() ?? ""
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
                if authType == .password {
                    existing.storePassword(password)
                } else {
                    existing.storePrivateKey(privateKeyPEM)
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
                password: usingVault
                    ? nil
                    : (authType == .password ? password : nil),
                privateKeyPEM: usingVault
                    ? nil
                    : (authType == .privateKey ? privateKeyPEM : nil),
                groupRef: groupRef,
                credentialRef: selectedCredential
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
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            if let icon = group.icon, !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
