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
    @Query(sort: \LogProfile.createdAt)
    private var logProfiles: [LogProfile]

    let existingHost: HostItem?
    let onSave: (HostItem) -> Void

    @State private var viewModel: HostFormViewModel

    init(
        existingHost: HostItem? = nil,
        defaultPort: Int = 22,
        initialHost: String? = nil,
        onSave: @escaping (HostItem) -> Void
    ) {
        self.existingHost = existingHost
        self.onSave = onSave
        _viewModel = State(initialValue: HostFormViewModel(existingHost: existingHost, defaultPort: defaultPort, initialHost: initialHost))
    }

    private var matchingCredentials: [Credential] {
        vaultCredentials.filter { $0.type == .password || $0.type == .privateKey }
    }

    private var detectedPrivateKeyType: String? {
        let trimmed = viewModel.privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? SSHKeyDetection.detectPrivateKeyType(from: trimmed))?.description
    }

    var body: some View {
        @Bindable var vm = viewModel
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
                    TextField(i18n.t(.displayName), text: $vm.name)
                    TextField(i18n.t(.hostnameOrIp), text: $vm.host, prompt: Text(vm.name.isEmpty ? "" : vm.name))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    TextField(i18n.t(.port), text: $vm.port)
                    TextField(i18n.t(.username), text: $vm.username)
                        .autocorrectionDisabled()
                    GroupComboBoxView(group: $vm.group)
                    TextField(i18n.t(.customTag), text: $vm.customTag)
                        .autocorrectionDisabled()
                    if !vm.customTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: AppStyle.spacingM) {
                            ForEach(HostItem.tagPresetColors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                                    .overlay(Circle().stroke(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).opacity(isTagColorSelected(hex, selected: vm.customTagColorHex) ? 1 : 0))
                                    .onTapGesture { vm.customTagColorHex = hex }
                            }
                            ColorPicker("", selection: Binding(
                                get: { vm.customTagColorHex.map { Color(hex: $0) } ?? Color(hex: HostItem.tagPresetColors[0]) },
                                set: { vm.customTagColorHex = $0.hexString }
                            ), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                                .padding(.leading, AppStyle.spacingS)
                        }
                        .padding(.vertical, AppStyle.spacingXS)
                    }
                }

                Section(i18n.t(.authentication)) {
                    Picker(i18n.t(.credential), selection: $vm.selectedCredential) {
                        Text(i18n.t(.custom)).tag(Credential?.none)
                        ForEach(matchingCredentials, id: \.self) { cred in
                            Label(cred.name, systemImage: cred.type.symbolName)
                                .tag(Credential?.some(cred))
                        }
                    }
                    .onChange(of: vm.selectedCredential) { _, newCred in
                        vm.onCredentialChanged(newCred)
                    }

                    if !vm.usingVault {
                        Picker(i18n.t(.method), selection: $vm.authType) {
                            Text(i18n.t(.password)).tag(AuthType.password)
                            Text(i18n.t(.privateKey)).tag(AuthType.privateKey)
                            Text(i18n.t(.certificate)).tag(AuthType.certificate)
                            Text(i18n.t(.secureEnclave)).tag(AuthType.secureEnclave)
                        }
                        .pickerStyle(.segmented)

                        switch vm.authType {
                        case .password:
                            LabeledSecureField(title: i18n.t(.password), text: $vm.password)
                        case .privateKey:
                            PEMEditorField(text: $vm.privateKeyPEM, detectedType: detectedPrivateKeyType.map { i18n.tr(.detectedKeyType, args: $0) }, hint: i18n.t(.pastePemKey))
                            if let t = detectedPrivateKeyType, t.contains("sk-") {
                                Label("检测到 Security Key (sk-)，需触摸 YubiKey", systemImage: "key.viewfinder").font(.caption).foregroundStyle(.orange)
                            }
                            Toggle(isOn: Binding(
                                get: { vm.selectedCredential?.isSecurityKey ?? false },
                                set: { vm.selectedCredential?.isSecurityKey = $0 }
                            )) {
                                Label("FIDO2 / YubiKey (sk-)", systemImage: "key.viewfinder")
                            }.help("Security Key 需触摸确认")
                            if let cred = vm.selectedCredential, cred.isSecurityKey {
                                Text("将使用 SecurityKeyProvider，需按 YubiKey").font(.caption).foregroundStyle(.orange)
                            }
                        case .certificate:
                            HStack {
                                Text(i18n.t(.privateKey)).font(.headline)
                                Spacer()
                                Button(vm.useFilePickerForKey ? i18n.t(.pasteManually) : i18n.t(.selectFile)) { vm.useFilePickerForKey.toggle() }
                                    .font(.caption)
                            }
                            if vm.useFilePickerForKey {
                                FilePickerCard(url: $vm.privateKeyFileURL, content: $vm.privateKeyPEM, placeholder: i18n.t(.selectPrivateKeyFile))
                            } else {
                                PEMEditorField(text: $vm.privateKeyPEM, minHeight: 100, detectedType: detectedPrivateKeyType.map { i18n.tr(.detectedKeyType, args: $0) }, hint: i18n.t(.pastePemKey))
                            }
                            HStack {
                                Text(i18n.t(.certificate)).font(.headline)
                                Spacer()
                                Button(vm.useFilePickerForCert ? i18n.t(.pasteManually) : i18n.t(.selectFile)) { vm.useFilePickerForCert.toggle() }
                                    .font(.caption)
                            }
                            if vm.useFilePickerForCert {
                                FilePickerCard(url: $vm.certificateFileURL, content: $vm.certificatePEM, placeholder: i18n.t(.selectCertificateFile))
                            } else {
                                PEMEditorField(text: $vm.certificatePEM, minHeight: 100, hint: i18n.t(.pasteCertificate))
                            }
                        case .secureEnclave:
                            VStack(alignment: .leading, spacing: 12) {
                                Text(i18n.t(.hardwareProtectionDesc)).font(.caption).foregroundStyle(.secondary)
                                if let selectedTag = vm.secureEnclaveKeyTag, !selectedTag.isEmpty {
                                    GroupBox {
                                        HStack {
                                            Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                                            VStack(alignment: .leading) {
                                                Text(selectedTag).font(.headline)
                                                Text(i18n.t(.secureEnclave)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Button(i18n.t(.change)) { vm.secureEnclaveKeyTag = nil; vm.secureEnclaveKeyTagInput = "" }
                                                .buttonStyle(.bordered).controlSize(.small)
                                        }.padding(AppStyle.spacingM)
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(i18n.t(.keyIdentifierHint)).font(.caption).foregroundStyle(.secondary)
                                        TextField(i18n.t(.exampleKeyTag), text: $vm.secureEnclaveKeyTagInput).textFieldStyle(.roundedBorder)
                                        HStack {
                                            Button(i18n.t(.verifyKey)) { vm.verifySecureEnclaveKey(i18n: i18n) }
                                                .disabled(vm.secureEnclaveKeyTagInput.isEmpty)
                                            if let msg = vm.secureEnclaveVerificationMessage {
                                                Text(msg).font(.caption).foregroundStyle((vm.secureEnclaveKeyExists ?? false) ? .green : .red)
                                            }
                                        }
                                        Divider()
                                        Button(i18n.t(.generateSecureEnclaveKey)) { vm.showSecureEnclaveGenerator = true }.buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    } else if let cred = vm.selectedCredential {
                        LabeledContent(i18n.t(.credential)) { Label(cred.name, systemImage: cred.type.symbolName) }
                        if let credUsername = cred.username, !credUsername.isEmpty {
                            LabeledContent(i18n.t(.username)) { Text(credUsername) }
                        }
                    }
                }

                Section {
                    Toggle(i18n.t(.jumpHostAdvanced), isOn: $vm.showJumpHost)
                    if vm.showJumpHost {
                        Picker(i18n.t(.jumpHosts), selection: $vm.selectedJumpHost) {
                            Text(i18n.t(.none)).tag(JumpHost?.none)
                            ForEach(jumpHosts) { jumpHost in Text(jumpHost.displayString).tag(JumpHost?.some(jumpHost)) }
                        }.disabled(jumpHosts.isEmpty)
                        if jumpHosts.isEmpty {
                            Text(i18n.t(.noJumpHosts)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("日志着色") {
                    Picker("着色配置", selection: $vm.selectedLogProfile) {
                        Text("跟随默认").tag(LogProfile?.none)
                        ForEach(logProfiles, id: \.self) { p in Text(p.name).tag(LogProfile?.some(p)) }
                    }
                }

                if let existing = existingHost {
                    Section(i18n.t(.sshEngineDiagnosis)) { HostConnectionDiagnosisView(host: existing) }
                } else {
                    Section(i18n.t(.sshEngineDiagnosis)) {
                        Toggle(isOn: $vm.forceCompatibilityToggle) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i18n.t(.sshAlwaysCompatibility)).font(.system(size: AppStyle.fontBody, weight: .medium))
                                Text(i18n.t(.sshAlwaysCompatibilityDesc)).font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: AppStyle.panelWidthMedium, maxHeight: 640)
        .fixedSize(horizontal: false, vertical: false)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(i18n.t(.cancel)) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) {
                    viewModel.save(hostGroups: hostGroups, modelContext: modelContext, onSave: onSave, i18n: i18n)
                    dismiss()
                }
                .disabled(!viewModel.isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $viewModel.showSecureEnclaveGenerator) {
            SecureEnclaveKeyGeneratorView().environment(i18n)
                .onDisappear {
                    if let tag = viewModel.secureEnclaveKeyTag, !tag.isEmpty {
                        viewModel.verifySecureEnclaveKey(i18n: i18n)
                    }
                }
        }
    }

    private func isTagColorSelected(_ hex: String, selected: String?) -> Bool {
        if let sel = selected { return sel.uppercased() == hex.uppercased() }
        return hex.uppercased() == HostItem.tagPresetColors.first?.uppercased()
    }
}
