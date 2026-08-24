import SwiftUI
import UniformTypeIdentifiers

// MARK: - BonkFormFields
// Reusable field building blocks extracted from AddHostSheet / JumpHostEditSheet /
// KeychainManagerView. One visual language, one place to fix bugs.
//
// Usage:
//   LabeledSecureField(titleKey: i18n.t(.password), text: $password)
//   PEMEditorField(text: $privateKeyPEM, detectedType: detectedPrivateKeyType)
//   FilePickerCard(url: $fileURL, content: $pem, placeholder: i18n.t(.selectPrivateKeyFile))
//   CredentialPickerField(selection: $selectedCredential, credentials: matchingCredentials)

/// Password field with eye toggle — single source of truth for every auth form.
struct LabeledSecureField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    @State private var revealed = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: AppStyle.spacingS) {
                Group {
                    if revealed {
                        AutoEnglishPlainField(text: $text, placeholder: placeholder)
                    } else {
                        AutoEnglishSecureField(text: $text, placeholder: placeholder)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: AppStyle.fontBody))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Monospaced PEM editor with optional detected-type hint underneath.
struct PEMEditorField: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var detectedType: String?
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingXS) {
            if let hint {
                Text(hint)
                    .font(.system(size: AppStyle.fontCaption))
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(AppStyle.spacingXS)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall, style: .continuous)
                        .strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1)
                )
            if let detectedType {
                Label(detectedType, systemImage: "checkmark.shield")
                    .font(.system(size: AppStyle.fontCaption))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// File picker card — replaces the two identical `filePickerField` builders
/// that lived in AddHostSheet and JumpHostView.
struct FilePickerCard: View {
    @Binding var url: URL?
    @Binding var content: String
    let placeholder: String
    var icon: String = "folder"

    var body: some View {
        Group {
            if let fileURL = url {
                HStack(spacing: AppStyle.spacingM) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.blue)
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: AppStyle.fontCaption))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        url = nil
                        content = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(AppStyle.spacingM)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall, style: .continuous)
                        .strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1)
                )
            } else {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.item]
                    if panel.runModal() == .OK, let selected = panel.url {
                        url = selected
                        if let data = try? Data(contentsOf: selected),
                           let str = String(data: data, encoding: .utf8)
                        {
                            content = str
                        }
                    }
                } label: {
                    HStack(spacing: AppStyle.spacingS) {
                        Image(systemName: icon)
                        Text(placeholder)
                            .font(.system(size: AppStyle.fontSmall))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(AppStyle.spacingM)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall, style: .continuous)
                            .strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Segmented auth-method picker row (password / privateKey / certificate / secureEnclave)
/// Keeps the 4-way choice visually consistent across host / jump-host forms.
struct AuthMethodPickerRow<Auth: Hashable & CaseIterable>: View where Auth: RawRepresentable, Auth.RawValue == String {
    let title: String
    @Binding var selection: Auth
    let labels: [Auth: String]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Auth.allCases), id: \.self) { value in
                Text(labels[value] ?? value.rawValue).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - BonkFormScaffold helper

/// Minimal toolbar scaffold so every Form sheet has identical Cancel/Save
/// placement, disabled logic, and keyboard shortcuts.
struct FormToolbarSaveButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .disabled(!isEnabled)
            .keyboardShortcut(.defaultAction)
    }
}
