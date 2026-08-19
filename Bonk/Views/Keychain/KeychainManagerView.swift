import SwiftData
import SwiftUI

struct KeychainManagerView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Credential.createdAt, order: .reverse)
    private var credentials: [Credential]

    @State private var editing: Credential?
    @State private var isAdding = false
    @State private var editName = ""
    @State private var editType: CredentialType = .password
    @State private var editUsername = ""
    @State private var editPassword = ""
    @State private var editPrivateKey = ""
    @State private var editNotes = ""
    @State private var showPassword = false
    @State private var pendingDelete: Credential?

    private var isEditing: Bool {
        isAdding || editing != nil
    }

    private var canSave: Bool {
        let secretFilled = editType == .password ? !editPassword.isEmpty : !editPrivateKey.isEmpty
        return !editName.trimmingCharacters(in: .whitespaces).isEmpty && secretFilled
    }

    var body: some View {
        Group {
            if isEditing {
                editForm
            } else {
                listView
            }
        }
        .frame(minWidth: 420, minHeight: 300, idealHeight: isEditing ? 500 : nil, maxHeight: isEditing ? 600 : nil)
        .navigationTitle(isEditing ? (isAdding ? i18n.t(.addCredential) : i18n.t(.editCredential)) : i18n.t(.keychain))
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) { save() }
                        .disabled(!canSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .alert(i18n.t(.removeProviderQ), isPresented: deleteAlertBinding) {
            Button(i18n.t(.delete), role: .destructive) {
                if let cred = pendingDelete { performDelete(cred) }
                pendingDelete = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDelete = nil }
        }
        .alert(
            "Overwrite private key?",
            isPresented: privateKeyOverwriteBinding
        ) {
            Button("Overwrite", role: .destructive) {
                if let cred = pendingPrivateKeyOverwrite {
                    performSave(cred.name)
                }
                pendingPrivateKeyOverwrite = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingPrivateKeyOverwrite = nil }
        } message: {
            Text("This replaces the stored private key. Use the password type instead if you only want to store a password.")
        }
    }

    private var privateKeyOverwriteBinding: Binding<Bool> {
        Binding(get: { pendingPrivateKeyOverwrite != nil }, set: { if !$0 { pendingPrivateKeyOverwrite = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: - List

    private var listView: some View {
        VStack(spacing: 0) {
            if credentials.isEmpty {
                ContentUnavailableView(
                    i18n.t(.noCredentials), systemImage: "key.fill",
                    description: Text(i18n.t(.noCredentialsHint))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(credentials) { cred in
                        HStack(spacing: 10) {
                            Image(systemName: cred.type.symbolName).foregroundStyle(.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cred.name).lineLimit(1)
                                Text(cred.type.displayName(i18n)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { beginEdit(cred) }
                    }
                    .onDelete { offsets in
                        if let idx = offsets.first { pendingDelete = credentials[idx] }
                    }
                }
            }

            Divider()

            HStack {
                Button { beginAdd() } label: {
                    Label(i18n.t(.addCredential), systemImage: "plus")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Edit Form

    private var editForm: some View {
        Form {
            Section(i18n.t(.name)) {
                TextField(i18n.t(.name), text: $editName)
            }
            Section(i18n.t(.credential)) {
                Picker(i18n.t(.credential), selection: $editType) {
                    ForEach(CredentialType.allCases, id: \.self) {
                        Label($0.displayName(i18n), systemImage: $0.symbolName)
                    }
                }
                .pickerStyle(.segmented)
                if editType == .password {
                    TextField(i18n.t(.username), text: $editUsername).autocorrectionDisabled()
                }
            }
            Section(editType == .privateKey ? i18n.t(.privateKey) : i18n.t(.password)) {
                if editType == .privateKey {
                    TextEditor(text: $editPrivateKey).font(.system(.caption, design: .monospaced)).frame(minHeight: 120)
                    Label("Private key PEM content — overwriting replaces the key used for authentication", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 6) {
                        if showPassword {
                            TextField(i18n.t(.password), text: $editPassword)
                        } else {
                            SecureField(i18n.t(.password), text: $editPassword)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(i18n.t(.password))
                    }
                }
            }
            Section(i18n.t(.notes)) {
                TextEditor(text: $editNotes).frame(minHeight: 60)
            }
            if editing != nil {
                Section {
                    Button(role: .destructive) { pendingDelete = editing } label: {
                        Label(i18n.t(.delete), systemImage: "trash").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func beginAdd() {
        editName = ""; editType = .password; editUsername = ""
        editPassword = ""; editPrivateKey = ""; editNotes = ""
        isAdding = true
    }

    private func beginEdit(_ cred: Credential) {
        editName = cred.name; editType = cred.type
        editUsername = cred.username ?? ""
        editPassword = cred.type == .password ? cred.loadSecret() ?? "" : ""
        editPrivateKey = cred.type == .privateKey ? cred.loadSecret() ?? "" : ""
        editNotes = cred.notes ?? ""
        editing = cred
    }

    private func cancel() {
        isAdding = false; editing = nil
    }

    private func save() {
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        if let existing = editing, existing.type == .privateKey, editType == .privateKey {
            // Overwriting an existing private key silently destroys the key
            // material — require an explicit confirm.
            pendingPrivateKeyOverwrite = existing
            return
        }
        performSave(trimmed)
    }

    @State private var pendingPrivateKeyOverwrite: Credential?

    private func performSave(_ trimmed: String) {
        let secret = editType == .password ? editPassword : editPrivateKey
        if let existing = editing {
            existing.name = trimmed; existing.type = editType
            existing.username = editType == .password ? editUsername : nil
            existing.notes = editNotes.isEmpty ? nil : editNotes
            existing.storeSecret(secret)
        } else {
            let cred = Credential(
                name: trimmed, type: editType,
                username: editType == .password ? editUsername : nil,
                notes: editNotes.isEmpty ? nil : editNotes
            )
            modelContext.insert(cred)
            cred.storeSecret(secret)
        }
        try? modelContext.save(); cancel()
    }

    private func performDelete(_ cred: Credential) {
        cred.deleteSecret(); modelContext.delete(cred); try? modelContext.save(); editing = nil
    }
}
