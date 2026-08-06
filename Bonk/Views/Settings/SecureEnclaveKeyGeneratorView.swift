//
//  SecureEnclaveKeyGeneratorView.swift
//  Bonk
//
//  Secure Enclave key generation UI.
//

import SwiftUI

/// UI for generating Secure Enclave P256 key pairs.
struct SecureEnclaveKeyGeneratorView: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss

    @State private var keyTag = ""
    @State private var generatedPublicKey: String?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Content
            if let publicKey = generatedPublicKey {
                keyPreviewSection(publicKey)
            } else {
                keyConfigSection
            }

            Divider()

            // Footer
            footerSection
        }
        .frame(minWidth: 500, minHeight: 400)
        .alert(i18n.t(.unknownError), isPresented: .constant(errorMessage != nil)) {
            Button(i18n.t(.ok)) { errorMessage = nil }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text(i18n.t(.generateSecureEnclaveKey))
                    .font(.headline)
                Spacer()
            }

            Text(i18n.t(.generateSecureEnclaveKeyDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    // MARK: - Key Config

    private var keyConfigSection: some View {
        Form {
            Section(i18n.t(.keyIdentifier)) {
                TextField(i18n.t(.exampleKeyTag), text: $keyTag)
                    .textFieldStyle(.roundedBorder)

                Text(i18n.t(.keyIdentifierHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(i18n.t(.hardwareProtection))
                            .font(.headline)
                        Text(i18n.t(.hardwareProtectionDesc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Image(systemName: "touchid")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(i18n.t(.biometricAuth))
                            .font(.headline)
                        Text(i18n.t(.biometricAuthDesc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(i18n.t(.securityFeatures))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Key Preview

    private func keyPreviewSection(_ publicKey: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Success message
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(i18n.t(.secureEnclaveKeyGenerated))
                        .font(.headline)
                }
                .padding()
                .background(.green.opacity(0.1))
                .cornerRadius(8)

                // Key info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent(i18n.t(.keyType)) {
                            Text("ECDSA P256 (Secure Enclave)")
                        }
                        LabeledContent(i18n.t(.keyIdentifier)) {
                            Text(keyTag)
                        }
                        LabeledContent("Security") {
                            Text(i18n.t(.hardwareNonExportable))
                                .foregroundStyle(.green)
                        }
                    }
                }

                // Public key
                GroupBox(i18n.t(.addPublicKeyToServer)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)

                        HStack {
                            Button {
                                copyToClipboard(publicKey)
                            } label: {
                                Label(i18n.t(.copyPublicKey), systemImage: "doc.on.doc")
                            }

                            Spacer()

                            Button {
                                saveToFile(publicKey, suggestedName: "id_ecdsa.pub")
                            } label: {
                                Label(i18n.t(.saveToFile), systemImage: "square.and.arrow.down")
                            }
                        }
                        .font(.caption)
                    }
                }

                if showCopied {
                    Text(i18n.t(.copied))
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding()
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if generatedPublicKey != nil {
                Button(i18n.t(.generateNew)) {
                    withAnimation {
                        generatedPublicKey = nil
                        keyTag = ""
                    }
                }
            }

            Spacer()

            Button(i18n.t(.cancel)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if generatedPublicKey == nil {
                Button {
                    generateKey()
                } label: {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(i18n.t(.generate))
                    }
                }
                .disabled(keyTag.isEmpty || isGenerating)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(i18n.t(.done)) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func generateKey() {
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                // Generate the key first (this will trigger Touch ID / password prompt)
                try SecureEnclaveKeyManager.generateKey(tag: keyTag)
                // Then export the public key
                let publicKey = try SecureEnclaveKeyManager.exportPublicKey(tag: keyTag)
                withAnimation {
                    generatedPublicKey = publicKey
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation {
            showCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopied = false
            }
        }
    }

    private func saveToFile(_ content: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Preview

#Preview {
    SecureEnclaveKeyGeneratorView()
        .environment(I18n())
}
