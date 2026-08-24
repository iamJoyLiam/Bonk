//
//  JumpHostView.swift
//  Bonk
//

import Citadel
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var hoveredHostID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                icon: "arrow.triangle.swap",
                title: i18n.t(.jumpHosts),
                count: jumpHosts.isEmpty ? nil : jumpHosts.count,
                trailing: AnyView(
                    PanelAddButton(help: i18n.t(.addJumpHost)) { showAddSheet = true }
                )
            )
            Divider()
            if jumpHosts.isEmpty {
                PanelEmptyView(
                    icon: "arrow.triangle.swap",
                    title: i18n.t(.noJumpHosts),
                    hint: i18n.t(.jumpHostHint)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: AppStyle.spacingS) {
                        ForEach(jumpHosts) { host in
                            hostRow(host)
                        }
                    }
                    .padding(AppStyle.spacingL)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
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
        let isHovered = hoveredHostID == host.id
        return HStack(spacing: AppStyle.spacingL) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: AppStyle.fontMedium))
                .foregroundStyle(.blue)
                .frame(width: AppStyle.buttonLarge, height: AppStyle.buttonLarge)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.system(size: AppStyle.fontRegular, weight: .medium))
                    .lineLimit(1)
                Text(host.displayString)
                    .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppStyle.spacingM)
            Button { editingHost = host } label: {
                Image(systemName: "pencil")
                    .font(.system(size: AppStyle.fontSmall, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(i18n.t(.edit))
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(isHovered ? 0.06 : 0.03), radius: isHovered ? 8 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.08 : 0.04), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hoveredHostID = hovering ? host.id : nil }
        }
        .onTapGesture { editingHost = host }
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
        guard let authMethod = host.resolveAuthMethod() else {
            testResult = false
            return
        }
        testingHostID = host.id
        testResult = nil

        Task {
            do {
                try await jumpHostService.testConnection(
                    host: host.host,
                    port: host.port,
                    username: host.username,
                    authMethod: authMethod
                )
                await MainActor.run {
                    testResult = true
                    testingHostID = nil
                }
            } catch {
                await MainActor.run {
                    testResult = false
                    testingHostID = nil
                }
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
    @State private var useFilePickerForKey = false
    @State private var selectedCredential: Credential?
    @State private var testing = false
    @State private var testResult: Bool?
    @State private var testMessage = ""
    @State private var privateKeyFileURL: URL?

    enum JumpAuthStyle: String, CaseIterable {
        case password, privateKey, credential
    }

    var jumpHostService = JumpHostService.shared

    private var detectedPrivateKeyType: String? {
        let trimmed = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? SSHKeyDetection.detectPrivateKeyType(from: trimmed))?.description
    }

    private var canTest: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && (Int(port) ?? 0) > 0
            && resolvedUsername != nil
    }

    /// Username for the jump host: the typed one, or the credential's when a
    /// vault credential is selected (so selecting a credential never forces
    /// re-typing the user).
    private var resolvedUsername: String? {
        let typed = username.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        if authStyle == .credential,
           let credUser = selectedCredential?.username,
           !credUser.isEmpty
        {
            return credUser
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: AppStyle.spacingM) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                    Text(host == nil ? i18n.t(.addJumpHost) : i18n.t(.editJumpHost))
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
                        text: $hostname,
                        prompt: Text(name.isEmpty ? "" : name)
                    )
                    .onChange(of: hostname) { _, newValue in
                        // Parse "user@host:port" shorthand as the user types.
                        let parsed = SSHHostParser.parse(newValue)
                        if let parsedUser = parsed.username,
                           !parsedUser.isEmpty,
                           username.isEmpty
                        {
                            username = parsedUser
                        }
                        if let parsedPort = parsed.port {
                            port = String(parsedPort)
                        }
                    }
                    TextField(i18n.t(.port), text: $port)
                        .font(.system(size: AppStyle.fontRegular, design: .monospaced))
                    TextField(i18n.t(.username), text: $username)
                        .autocorrectionDisabled()
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
                        LabeledSecureField(title: i18n.t(.password), text: $password)
                    case .privateKey:
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
                                detectedType: detectedPrivateKeyType.map { i18n.tr(.detectedKeyType, args: $0) },
                                hint: i18n.t(.pastePemKey)
                            )
                        }
                    case .credential:
                        Picker(i18n.t(.credential), selection: $selectedCredential) {
                            Text(i18n.t(.custom)).tag(Credential?.none)
                            ForEach(credentials.filter { $0.type == .password || $0.type == .privateKey }) { credential in
                                Label(credential.name, systemImage: credential.type.symbolName)
                                    .tag(Credential?.some(credential))
                            }
                        }
                        .onChange(of: selectedCredential) { _, newCred in
                            // Bring the credential's username along — the user
                            // should never have to type it twice.
                            if let newCred, let credUser = newCred.username,
                               !credUser.isEmpty, username.isEmpty
                            {
                                username = credUser
                            }
                        }
                    }
                }

                Section(i18n.t(.connection)) {
                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            if testing {
                                ProgressView().controlSize(.small)
                                Text(i18n.t(.testConnection))
                            } else {
                                Label(i18n.t(.testConnection), systemImage: "network")
                            }
                        }
                        .disabled(!canTest || testing || !canBuildAuth)
                        .buttonStyle(.bordered)

                        if let testResult, !testing {
                            Image(systemName: testResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testResult ? .green : .red)
                            Text(testMessage)
                                .font(.caption)
                                .foregroundStyle(testResult ? .green : .red)
                        }
                    }
                }
                }
                .formStyle(.grouped)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        save()
                        dismiss()
                    }
                    .disabled(name.isEmpty || hostname.isEmpty || resolvedUsername == nil)
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
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: AppStyle.panelWidthMedium)
    }

    private var canBuildAuth: Bool {
        switch authStyle {
        case .password: !password.isEmpty
        case .privateKey: !privateKeyPEM.isEmpty
        case .credential: selectedCredential != nil
        }
    }

    private func buildAuthMethod() -> SSHAuthMethod? {
        switch authStyle {
        case .password: return SSHAuthMethod.password(password)
        case .privateKey: return SSHAuthMethod.privateKey(pemString: privateKeyPEM)
        case .credential:
            guard let selectedCredential,
                  let secret = selectedCredential.loadSecret(),
                  !secret.isEmpty
            else { return nil }
            switch selectedCredential.type {
            case .password: return .password(secret)
            case .privateKey: return .privateKey(pemString: secret)
            case .apiKey: return nil
            }
        }
    }

    private func testConnection() {
        guard let authMethod = buildAuthMethod(),
              let effectiveUsername = resolvedUsername
        else { return }
        let portInt = Int(port) ?? 22

        testing = true
        testResult = nil
        testMessage = ""
        Task {
            do {
                try await jumpHostService.testConnection(
                    host: hostname.trimmingCharacters(in: .whitespaces),
                    port: portInt,
                    username: effectiveUsername,
                    authMethod: authMethod
                )
                await MainActor.run {
                    testing = false
                    testResult = true
                    testMessage = i18n.t(.connectionSuccessful)
                }
            } catch {
                await MainActor.run {
                    testing = false
                    testResult = false
                    testMessage = error.localizedDescription
                }
            }
        }
    }

    // FilePickerCard now lives in Bonk/Views/Common/BonkFormFields.swift

    private func save() {
        let portInt = Int(port) ?? 22
        let effectiveUsername = resolvedUsername ?? username

        if let host {
            host.name = name
            host.host = hostname
            host.port = portInt
            host.username = effectiveUsername
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
                username: effectiveUsername
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
