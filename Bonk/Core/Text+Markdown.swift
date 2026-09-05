import MarkdownUI
import SwiftUI

// MARK: - Rich Markdown View (powered by MarkdownUI)

struct MarkdownTextView: View {
    let content: String
    var onRun: (@MainActor (String) -> Void)?

    var body: some View {
        MarkdownUI.Markdown(content, baseURL: nil)
            .markdownTheme(.bonk(onRun: onRun))
            .textSelection(.enabled)
    }
}

// MARK: - Bonk Theme

extension MarkdownUI.Theme {
    static func bonk(onRun: (@MainActor (String) -> Void)? = nil) -> MarkdownUI.Theme {
        var theme = Theme.basic

        // Code blocks with compact ChatGPT-like spacing
        theme.codeBlock = BlockStyle<CodeBlockConfiguration> { configuration in
            VStack(alignment: .leading, spacing: 0) {
                if let onRun {
                    InteractiveCodeBlock(
                        code: configuration.content,
                        language: configuration.language,
                        onRun: onRun
                    )
                } else {
                    CodeBlockView(
                        code: configuration.content,
                        language: configuration.language
                    )
                }
            }
            .padding(.vertical, 4)
        }

        // Lists with compact indentation and spacing
        theme.list = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .padding(.leading, 12)
                .padding(.vertical, 2)
        }

        // List items with tight spacing
        theme.listItem = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .padding(.vertical, 1)
        }

        // Paragraphs with comfortable line spacing and compact margins
        theme.paragraph = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .lineSpacing(3)
                .padding(.vertical, 2)
        }

        // Headings — sized by level, tight margins, native macOS typography.
        theme.heading1 = headingStyle(size: 14)
        theme.heading2 = headingStyle(size: 13)
        theme.heading3 = headingStyle(size: 12.5)
        theme.heading4 = headingStyle(size: 12)

        // Blockquotes — left accent bar, muted text.
        theme.blockquote = BlockStyle<BlockConfiguration> { configuration in
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                configuration.label
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }

        // Tables — card background, readable header.
        theme.table = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .font(.system(size: 12))
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.vertical, 2)
        }

        return theme
    }

    private static func headingStyle(size: CGFloat) -> BlockStyle<BlockConfiguration> {
        BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .font(.system(size: size, weight: .semibold))
                .padding(.top, 5)
                .padding(.bottom, 2)
        }
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
                if let lang = language, !lang.isEmpty {
                    Text(lang.lowercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))

            Divider().opacity(0.2)

            // Code content
            HighlightedCodeLines(code: code)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }
}
