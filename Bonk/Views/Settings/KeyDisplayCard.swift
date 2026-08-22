import SwiftUI

/// Shared card for displaying generated SSH keys with copy/save actions.
struct KeyDisplayCard: View {
    let title: String
    let keyText: String
    let fingerprint: String?
    var onCopy: (() -> Void)?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.spacingM) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(keyText)
                    .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(AppStyle.spacingM)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall))
            }
            if let fingerprint {
                Text(fingerprint)
                    .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: AppStyle.spacingM) {
                Button { copy() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                if let onCopy {
                    Button("Save to File", action: onCopy)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(AppStyle.spacingL)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium))
        .overlay(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium).strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keyText, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
        onCopy?()
    }
}
