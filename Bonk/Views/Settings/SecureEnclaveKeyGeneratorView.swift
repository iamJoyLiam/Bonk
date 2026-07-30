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
                Text("Generate Secure Enclave Key")
                    .font(.headline)
                Spacer()
            }

            Text("Create a hardware-protected SSH key using Apple Secure Enclave. Touch ID or password will be required for authentication.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    // MARK: - Key Config

    private var keyConfigSection: some View {
        Form {
            Section("Key Identifier") {
                TextField("e.g., my-server, production", text: $keyTag)
                    .textFieldStyle(.roundedBorder)

                Text("A unique name to identify this key. Used for SSH authentication.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Hardware Protection")
                            .font(.headline)
                        Text("Private key is generated and stored in Secure Enclave. It never leaves the hardware and cannot be exported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Image(systemName: "touchid")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Biometric Authentication")
                            .font(.headline)
                        Text("Each SSH login will require Touch ID or password confirmation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Security Features")
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
                    Text("Secure Enclave key generated successfully!")
                        .font(.headline)
                }
                .padding()
                .background(.green.opacity(0.1))
                .cornerRadius(8)

                // Key info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Key Type") {
                            Text("ECDSA P256 (Secure Enclave)")
                        }
                        LabeledContent("Key Identifier") {
                            Text(keyTag)
                        }
                        LabeledContent("Security") {
                            Text("Hardware-protected, non-exportable")
                                .foregroundStyle(.green)
                        }
                    }
                }

                // Public key
                GroupBox("Public Key (add to server ~/.ssh/authorized_keys)") {
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
                        Text("Generate Key")
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
                // This will trigger Touch ID / password prompt
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
