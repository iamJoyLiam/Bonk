//
//  SSHKeyGeneratorView.swift
//  Bonk
//
//  SSH key generation UI with preview and export.
//

import os.log
import SwiftUI

// MARK: - Key Generator View

/// UI for generating SSH key pairs.
struct SSHKeyGeneratorView: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: SSHKeyType = .ed25519
    @State private var passphrase = ""
    @State private var showPassphrase = false
    @State private var generatedKey: GeneratedSSHKey?
    @State private var isGenerating = false
    @State private var showCopied = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Content
            if let key = generatedKey {
                keyPreviewSection(key)
            } else {
                keyConfigSection
            }

            Divider()

            // Footer
            footerSection
        }
        .frame(minWidth: AppStyle.settingsWindowHeight, minHeight: AppStyle.serialPortWidth)
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
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text(i18n.t(.generateSSHKey))
                    .font(.headline)
                Spacer()
            }

            Text(i18n.t(.generateSSHKeyDescription))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    // MARK: - Key Config

    private var keyConfigSection: some View {
        Form {
            Section(i18n.t(.keyType)) {
                Picker("", selection: $selectedType) {
                    ForEach(SSHKeyType.allCases, id: \.self) { type in
                        VStack(alignment: .leading) {
                            Text(type.displayName)
                            Text(type.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(type)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section(i18n.t(.passphraseOptional)) {
                HStack {
                    if showPassphrase {
                        TextField(i18n.t(.passphraseOptional), text: $passphrase)
                    } else {
                        SecureField(i18n.t(.passphraseOptional), text: $passphrase)
                    }
                    Button {
                        showPassphrase.toggle()
                    } label: {
                        Image(systemName: showPassphrase ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(i18n.t(.passphraseHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Key Preview

    private func keyPreviewSection(_ key: GeneratedSSHKey) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Key info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent(i18n.t(.keyType)) {
                            Text(key.type.displayName)
                        }
                        LabeledContent(i18n.t(.fingerprint)) {
                            HStack {
                                Text(key.fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                Button {
                                    copyToClipboard(key.fingerprint)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Public key
                GroupBox(i18n.t(.publicKey)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.publicKeySSH)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)

                        HStack {
                            Button {
                                copyToClipboard(key.publicKeySSH)
                            } label: {
                                Label(i18n.t(.copyPublicKey), systemImage: "doc.on.doc")
                            }

                            Spacer()

                            Button {
                                saveToFile(key.publicKeySSH, suggestedName: "id_\(key.type.rawValue.lowercased()).pub")
                            } label: {
                                Label(i18n.t(.saveToFile), systemImage: "square.and.arrow.down")
                            }
                        }
                        .font(.caption)
                    }
                }

                // Private key
                GroupBox(i18n.t(.privateKeyAuth)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(i18n.t(.privateKeyWarning))
                            .font(.caption)
                            .foregroundStyle(.orange)

                        Text(key.privateKeyPEM)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(10)
                            .frame(maxHeight: 150)

                        HStack {
                            Button {
                                copyToClipboard(key.privateKeyPEM)
                            } label: {
                                Label(i18n.t(.copyPrivateKey), systemImage: "doc.on.doc")
                            }

                            Spacer()

                            Button {
                                saveToFile(key.privateKeyPEM, suggestedName: "id_\(key.type.rawValue.lowercased())")
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
            if generatedKey != nil {
                Button(i18n.t(.generateNew)) {
                    withAnimation {
                        generatedKey = nil
                    }
                }
            }

            Spacer()

            Button(i18n.t(.cancel)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if generatedKey == nil {
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
                .disabled(isGenerating)
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
                let key = try SSHKeyGenerator.generate(type: selectedType)
                withAnimation {
                    generatedKey = key
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
