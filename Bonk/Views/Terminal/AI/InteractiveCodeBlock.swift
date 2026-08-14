import SwiftUI

/// Interactive code block. One Run button sends the command to the live
/// terminal (visible execution); Copy is always available.
struct InteractiveCodeBlock: View {
    @Environment(I18n.self) var i18n
    let code: String
    let language: String?
    var onRun: (@MainActor (String) -> Void)?
    @State private var copied = false

    private var isShellLanguage: Bool {
        guard let lang = language?.lowercased() else { return true }
        return ["bash", "sh", "zsh", "shell"].contains(lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)

                if let lang = language {
                    Text(lang.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isShellLanguage, let onRun {
                    Button { onRun(code) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text(i18n.t(.aiRun))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlColor).opacity(0.5))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}
