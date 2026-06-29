import MarkdownUI
import SwiftUI

// MARK: - Text Extension (for backward compatibility)

extension Text {
    /// Render text with basic markdown support. Falls back to plain text on failure.
    static func markdown(_ content: String) -> Text {
        if let attr = try? AttributedString(markdown: content) { return Text(attr) }
        return Text(content)
    }
}

// MARK: - Rich Markdown View (powered by MarkdownUI)

struct MarkdownTextView: View {
    let content: String
    var sshService: SSHNetworkService?

    var body: some View {
        MarkdownUI.Markdown(content, baseURL: nil)
            .markdownTheme(.bonk(sshService: sshService))
    }
}

// MARK: - Bonk Theme

extension MarkdownUI.Theme {
    static func bonk(sshService: SSHNetworkService?) -> MarkdownUI.Theme {
        var theme = Theme.basic

        // Code blocks with proper spacing to prevent sticking to adjacent text
        theme.codeBlock = BlockStyle<CodeBlockConfiguration> { configuration in
            VStack(alignment: .leading, spacing: 0) {
                if let ssh = sshService {
                    InteractiveCodeBlock(
                        code: configuration.content,
                        language: configuration.language,
                        sshService: ssh
                    )
                } else {
                    CodeBlockView(
                        code: configuration.content,
                        language: configuration.language
                    )
                }
            }
            .padding(.vertical, 8)
        }

        // Lists with proper indentation and spacing
        theme.list = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .padding(.leading, 8)
                .padding(.vertical, 4)
        }

        // List items with spacing between them
        theme.listItem = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .padding(.vertical, 2)
        }

        // Paragraphs with line spacing
        theme.paragraph = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .lineSpacing(4)
                .padding(.vertical, 4)
        }

        return theme
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    var language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                if let lang = language {
                    Text(lang)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
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
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlColor).opacity(0.5))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlColor).opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
