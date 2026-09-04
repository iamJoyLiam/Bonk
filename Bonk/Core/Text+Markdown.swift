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
            .padding(.vertical, AppStyle.spacingM)
        }

        // Lists with proper indentation and spacing
        theme.list = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .padding(.leading, AppStyle.spacingM)
                .padding(.vertical, AppStyle.spacingXS)
        }

        // List items with spacing between them
        theme.listItem = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .padding(.vertical, AppStyle.spacingXXS)
        }

        // Paragraphs with line spacing
        theme.paragraph = BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .lineSpacing(4)
                .padding(.vertical, AppStyle.spacingXS)
        }

        // Headings — sized by level, tight margins, native macOS typography.
        theme.heading1 = headingStyle(size: 15)
        theme.heading2 = headingStyle(size: 13.5)
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
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.vertical, 3)
        }

        return theme
    }

    private static func headingStyle(size: CGFloat) -> BlockStyle<BlockConfiguration> {
        BlockStyle<BlockConfiguration> { configuration in
            configuration.label
                .font(.system(size: size, weight: .semibold))
                .padding(.top, 6)
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
                        .font(.system(size: AppStyle.fontSmallest, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppStyle.spacingS)
                        .padding(.vertical, AppStyle.spacingXXS)
                        .background(Color.accentColor.opacity(AppStyle.opacityBackgroundStrong))
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
                        .font(.system(size: AppStyle.fontCaption))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppStyle.spacingML)
            .padding(.vertical, AppStyle.spacingSPlus)
            .background(Color(nsColor: .controlColor).opacity(AppStyle.opacityDisabled))

            // Code content
            HighlightedCodeLines(code: code)
        }
        .background(Color(nsColor: .controlColor).opacity(AppStyle.opacityOverlayDim))
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall))
    }
}
