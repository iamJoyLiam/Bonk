import SwiftUI
import SwiftData
import os.log

/// Auth retry sheet - simplified host editor for credential error.
/// Uses Form + Section like AddHostSheet for consistent macOS style.
struct AuthRetrySheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Credential.createdAt, order: .reverse) private var vaultCredentials: [Credential]

    let host: HostItem
    let rawError: String
    var onRetry: (SessionManager.AuthRetryResult) -> Void
    var onCancel: () -> Void
    var onEditFull: () -> Void

    @State private var viewModel: HostFormViewModel
    @State private var showDetails = false

    init(host: HostItem, rawError: String, lastAttemptPassword: String? = nil, onRetry: @escaping (SessionManager.AuthRetryResult) -> Void, onCancel: @escaping () -> Void, onEditFull: @escaping () -> Void) {
        self.host = host
        self.rawError = rawError
        self.onRetry = onRetry
        self.onCancel = onCancel
        self.onEditFull = onEditFull
        _viewModel = State(initialValue: HostFormViewModel(existingHost: host, overridePassword: lastAttemptPassword))
    }

    private var matchingCredentials: [Credential] {
        vaultCredentials.filter { $0.type == .password || $0.type == .privateKey }
    }

    var body: some View {
        @Bindable var viewModelBindable = viewModel
        VStack(spacing: 0) {
            // Header - match AddHostSheet style
            HStack(spacing: AppStyle.spacingM) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: AppStyle.iconHero))
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.t(.authFailedTitle)).font(.system(size: AppStyle.fontRegular, weight: .semibold))
                    Text("\(host.username)@\(host.host):\(host.port)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            Divider()
            Form {
                // Orange banner
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(i18n.t(.authFailedMessage), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button(showDetails ? i18n.t(.hideDetails) : i18n.t(.showDetails)) {
                            withAnimation { showDetails.toggle() }
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                        if showDetails {
                            Text(rawError.isEmpty ? i18n.t(.unknownError) : rawError)
                                .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(AppStyle.cornerRadiusSmall)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.orange.opacity(0.08))
                }

                Section(i18n.t(.hostInformation)) {
                    LabeledContent(i18n.t(.displayName), value: host.name)
                    LabeledContent(i18n.t(.hostnameOrIp), value: host.host)
                    LabeledContent(i18n.t(.username), value: host.username)
                    LabeledContent(i18n.t(.port), value: "\(host.port)")
                }

                Section(i18n.t(.authentication)) {
                    Picker(i18n.t(.credential), selection: $viewModelBindable.selectedCredential) {
                        Text(i18n.t(.custom)).tag(Credential?.none)
                        ForEach(matchingCredentials, id: \.self) { cred in
                            Label(cred.name, systemImage: cred.type.symbolName).tag(Credential?.some(cred))
                        }
                    }
                    .onChange(of: viewModel.selectedCredential) { _, new in viewModel.onCredentialChanged(new) }

                    if !viewModel.usingVault {
                        Picker(i18n.t(.method), selection: $viewModelBindable.authType) {
                            Text(i18n.t(.password)).tag(AuthType.password)
                            Text(i18n.t(.privateKey)).tag(AuthType.privateKey)
                            Text(i18n.t(.certificate)).tag(AuthType.certificate)
                            Text(i18n.t(.secureEnclave)).tag(AuthType.secureEnclave)
                        }
                        .pickerStyle(.segmented)

                        switch viewModel.authType {
                        case .password:
                            LabeledSecureField(title: i18n.t(.password), text: $viewModelBindable.password)
                                .onChange(of: viewModel.password) { _, newValue in Log.session.info("[AUTH_RETRY_SHEET] password changed len=\(newValue.count) fp=\(newValue.isEmpty ? "-" : OpenSSHBackend.passwordFingerprint(newValue))") }
                        case .privateKey:
                            PEMEditorField(text: $viewModelBindable.privateKeyPEM, hint: i18n.t(.pastePemKey))
                        case .certificate:
                            PEMEditorField(text: $viewModelBindable.privateKeyPEM, minHeight: 80, hint: i18n.t(.pastePemKey))
                            PEMEditorField(text: $viewModelBindable.certificatePEM, minHeight: 80, hint: i18n.t(.pasteCertificate))
                        case .secureEnclave:
                            TextField(i18n.t(.exampleKeyTag), text: $viewModelBindable.secureEnclaveKeyTagInput)
                                .textFieldStyle(.roundedBorder)
                        }
                    } else if let cred = viewModel.selectedCredential {
                        LabeledContent(i18n.t(.credential)) { Label(cred.name, systemImage: cred.type.symbolName) }
                        if let credUsername = cred.username, !credUsername.isEmpty {
                            LabeledContent(i18n.t(.username), value: credUsername)
                        }
                        // Allow vault override (persist after 300ms)
                        LabeledSecureField(title: i18n.t(.password) + " (\(i18n.t(.retry)))", text: $viewModelBindable.password)
                            .onChange(of: viewModel.password) { _, newValue in Log.session.info("[AUTH_RETRY_SHEET] vault override password changed len=\(newValue.count) fp=\(newValue.isEmpty ? "-" : OpenSSHBackend.passwordFingerprint(newValue))") }
                    }
                }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button(i18n.t(.cancel)) { onCancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(i18n.t(.retry)) {
                    let retryResult = buildRetryResult()
                    Log.session.info("[AUTH_RETRY_SHEET] retry tapped pwLen=\(retryResult.password.count) valid=\(viewModel.isValid)")
                    onRetry(retryResult)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isValid)
                .onAppear { Log.session.info("[AUTH_RETRY_SHEET] appear pwLen=\(viewModel.password.count) isValid=\(viewModel.isValid) password='\(viewModel.password.prefix(2))...'") }
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingM)
        }
        .frame(minWidth: AppStyle.panelWidthMedium, maxHeight: 640)
    }

    private func buildRetryResult() -> SessionManager.AuthRetryResult {
        let trimmedPassword = viewModel.password.trimmingCharacters(in: .whitespacesAndNewlines)
        // Log fingerprint for UI->retry trace without plaintext
        let fingerprint = trimmedPassword.isEmpty ? "-" : OpenSSHBackend.passwordFingerprint(trimmedPassword)
        let credDesc = viewModel.selectedCredential == nil ? "nil" : "\(viewModel.selectedCredential!.name)"
        Log.session.info("[AUTH_RETRY_SHEET] buildRetryResult pwLen=\(trimmedPassword.count) fingerprint=\(fingerprint, privacy: .public) authType=\(viewModel.authType.rawValue, privacy: .public) cred=\(credDesc, privacy: .public) usingVault=\(viewModel.usingVault)")
        return SessionManager.AuthRetryResult(
            password: trimmedPassword,
            privateKeyPEM: viewModel.privateKeyPEM,
            certificatePEM: viewModel.certificatePEM,
            secureEnclaveTag: viewModel.secureEnclaveKeyTagInput.isEmpty ? viewModel.secureEnclaveKeyTag : viewModel.secureEnclaveKeyTagInput,
            credentialID: viewModel.selectedCredential?.persistentModelID,
            authType: viewModel.authType
        )
    }
}
