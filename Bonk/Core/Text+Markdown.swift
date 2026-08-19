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

        // Code blocks with proper spacing to prevent sticking to adjacent text
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

        // Headings — sized by level, tight margins, no heavy decoration.
        theme.heading1 = headingStyle(size: 16)
        theme.heading2 = headingStyle(size: 14)
        theme.heading3 = headingStyle(size: 13)
        theme.heading4 = headingStyle(size: 12)

        // Blockquotes — left accent bar, muted text.
        theme.blockquote = BlockStyle<BlockConfiguration> { configuration in
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                configuration.label
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        // Tables — card background, readable header. Horizontally scrollable
        // so wide AI summaries (disk layout, resource stats) never get
        // squeezed into "…" in a narrow sidebar.
        theme.table = BlockStyle<BlockConfiguration> { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .padding(8)
                    .background(Color(nsColor: .controlColor).opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.vertical, 4)
        }

        return theme
    }

    private static func headingStyle(size: CGFloat) -> BlockStyle<BlockConfiguration> {
        BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .font(.system(size: size, weight: .semibold))
                .padding(.top, 8)
                .padding(.bottom, 3)
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
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
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
            HighlightedCodeLines(code: code)
        }
        .background(Color(nsColor: .controlColor).opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
