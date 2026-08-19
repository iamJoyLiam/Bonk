//
//  JumpHostView.swift
//  Bonk
//

import SwiftData
import SwiftUI

/// Jump host management panel.
struct JumpHostView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JumpHost.sortOrder) private var jumpHosts: [JumpHost]
    @Binding var isPresented: Bool

    @State private var showAddSheet = false
    @State private var editingHost: JumpHost?
    @State private var jumpHostService = JumpHostService.shared
    @State private var testingHostID: UUID?
    @State private var testResult: Bool?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundStyle(.blue)
                Text(i18n.t(.jumpHosts))
                    .font(.headline)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(i18n.t(.addJumpHost))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Hosts list
            if jumpHosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.noJumpHosts))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.jumpHostHint))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jumpHosts) { host in
                            hostRow(host)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showAddSheet) {
            JumpHostEditSheet(host: nil, modelContext: modelContext)
                .environment(i18n)
        }
        .sheet(item: $editingHost) { host in
            JumpHostEditSheet(host: host, modelContext: modelContext)
                .environment(i18n)
        }
    }

    private func hostRow(_ host: JumpHost) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
                .frame(width: 20)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.system(size: 13, weight: .medium))
                Text(host.displayString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Edit button
            Button {
                editingHost = host
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                editingHost = host
            } label: {
                Label(i18n.t(.edit), systemImage: "pencil")
            }
            Button {
                testConnection(host)
            } label: {
                Label(i18n.t(.testConnection), systemImage: "network")
            }
            .disabled(testingHostID == host.id)
            Divider()
            Button(role: .destructive) {
                modelContext.delete(host)
            } label: {
                Label(i18n.t(.delete), systemImage: "trash")
            }
        }
    }

    private func testConnection(_ host: JumpHost) {
        testingHostID = host.id
        testResult = nil

        Task {
            // 使用密码认证进行测试
            let credential = SSHAuthMethod.password("test")
            let result = try? await jumpHostService.testConnection(
                jumpHost: host,
                credential: credential
            )
            await MainActor.run {
                testResult = result
                testingHostID = nil
            }
        }
    }
}

// MARK: - Jump Host Edit Sheet

struct JumpHostEditSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    let host: JumpHost?
    let modelContext: ModelContext
    @Query(sort: \Credential.createdAt, order: .reverse)
    private var credentials: [Credential]

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authStyle: JumpAuthStyle = .credential
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @State private var showPassword = false
    @State private var selectedCredential: Credential?

    enum JumpAuthStyle: String, CaseIterable {
        case password, privateKey, credential
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(i18n.t(.name)) {
                    TextField(i18n.t(.name), text: $name)
                }

                Section(i18n.t(.host)) {
                    TextField(i18n.t(.hostname), text: $hostname)
                    TextField(i18n.t(.port), text: $port)
                        .font(.system(size: 13, design: .monospaced))
                }

                Section(i18n.t(.username)) {
                    TextField(i18n.t(.username), text: $username)
                }

                Section(i18n.t(.authentication)) {
                    Picker(i18n.t(.authentication), selection: $authStyle) {
                        Text(i18n.t(.password)).tag(JumpAuthStyle.password)
                        Text(i18n.t(.privateKey)).tag(JumpAuthStyle.privateKey)
                        Text(i18n.t(.credential)).tag(JumpAuthStyle.credential)
                    }
                    .pickerStyle(.segmented)

                    switch authStyle {
                    case .password:
                        HStack(spacing: 6) {
                            if showPassword {
                                TextField(i18n.t(.password), text: $password)
                            } else {
                                SecureField(i18n.t(.password), text: $password)
                            }
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    case .privateKey:
                        TextEditor(text: $privateKeyPEM)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                    case .credential:
                        Picker(i18n.t(.credential), selection: $selectedCredential) {
                            Text(i18n.t(.none)).tag(Credential?.none)
                            ForEach(credentials.filter { $0.type == .password || $0.type == .privateKey }) { credential in
                                Label(credential.name, systemImage: credential.type.symbolName)
                                    .tag(Credential?.some(credential))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(host == nil ? i18n.t(.addJumpHost) : i18n.t(.editJumpHost))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        save()
                        dismiss()
                    }
                    .disabled(name.isEmpty || hostname.isEmpty || username.isEmpty)
                }
            }
            .onAppear {
                if let host {
                    name = host.name
                    hostname = host.host
                    port = "\(host.port)"
                    username = host.username
                    // Legacy data saved by the old editor kept authType at
                    // the "password" default while authenticating via a vault
                    // credential — surface that as the credential style.
                    if host.authType == "password",
                       host.loadPassword() == nil,
                       host.credentialRef != nil
                    {
                        authStyle = .credential
                        selectedCredential = host.credentialRef
                    } else {
                        switch host.authType {
                        case "password":
                            authStyle = .password
                            password = host.loadPassword() ?? ""
                        case "privateKey":
                            authStyle = .privateKey
                            privateKeyPEM = host.loadPrivateKey() ?? ""
                        default:
                            authStyle = .credential
                        }
                        selectedCredential = host.credentialRef
                    }
                }
            }
        }
        .frame(width: 480, height: 420)
    }

    private func save() {
        let portInt = Int(port) ?? 22

        if let host {
            host.name = name
            host.host = hostname
            host.port = portInt
            host.username = username
            host.deleteInlineCredentials()
            host.credentialRef = nil
            switch authStyle {
            case .password:
                host.authType = "password"
                host.storePassword(password)
            case .privateKey:
                host.authType = "privateKey"
                host.storePrivateKey(privateKeyPEM)
            case .credential:
                host.authType = "credential"
                host.credentialRef = selectedCredential
            }
        } else {
            let newHost = JumpHost(
                name: name,
                host: hostname,
                port: portInt,
                username: username
            )
            newHost.credentialRef = selectedCredential
            switch authStyle {
            case .password:
                newHost.authType = "password"
                newHost.storePassword(password)
            case .privateKey:
                newHost.authType = "privateKey"
                newHost.storePrivateKey(privateKeyPEM)
            case .credential:
                newHost.authType = "credential"
                newHost.credentialRef = selectedCredential
            }
            modelContext.insert(newHost)
        }
    }
}
