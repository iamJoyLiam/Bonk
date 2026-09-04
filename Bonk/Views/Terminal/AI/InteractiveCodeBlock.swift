import SwiftUI

/// Interactive code block. One Run button sends the command to the live
/// terminal (visible execution); Copy is always available.
struct InteractiveCodeBlock: View {
    @Environment(I18n.self) var i18n
    let code: String
    let language: String?
    var onRun: (@MainActor (String) -> Void)?
    @State private var copied = false
    @State private var justExecuted = false

    private var isShellLanguage: Bool {
        guard let lang = language?.lowercased() else { return true }
        return ["bash", "sh", "zsh", "shell"].contains(lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: AppStyle.fontCaption))
                        .foregroundStyle(.green)

                    Text((language ?? "sh").uppercased())
                        .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isShellLanguage, let onRun {
                    Button {
                        justExecuted = true
                        onRun(code)
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            justExecuted = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: justExecuted ? "checkmark.circle.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(justExecuted ? i18n.t(.aiSent) : i18n.t(.aiRun))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(justExecuted ? Color.green : Color.accentColor)
                        .padding(.horizontal, AppStyle.spacingSPlus)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(justExecuted ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        if copied {
                            Text(i18n.t(.copied))
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundStyle(copied ? Color.green : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .controlColor).opacity(copied ? 0.3 : 0))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppStyle.spacingML)
            .padding(.vertical, AppStyle.spacingS)
            .background(Color(nsColor: .controlColor).opacity(AppStyle.opacityDisabled))

            // Code content
            HighlightedCodeLines(code: code)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall)
                .stroke(Color.secondary.opacity(AppStyle.opacityBackgroundLight), lineWidth: 1)
        )
    }
}
