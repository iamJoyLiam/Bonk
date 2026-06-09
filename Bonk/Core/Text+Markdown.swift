import SwiftUI

extension Text {
    /// Render text with markdown support including code blocks.
    /// SwiftUI's AttributedString(markdown:) renders fenced code blocks
    /// as inline code without background. This method preprocesses markdown
    /// to ensure code blocks are properly formatted.
    static func markdown(_ content: String) -> Text {
        // Preprocess: ensure fenced code blocks have proper syntax
        let processed = content
            .replacingOccurrences(of: "```\\w*\\n", with: "```\n", options: .regularExpression)
        if let attr = try? AttributedString(markdown: processed, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )) {
            return Text(attr)
        }
        // Fallback: try without options
        if let attr = try? AttributedString(markdown: processed) {
            return Text(attr)
        }
        return Text(content)
    }
}

// MARK: - Rich Markdown View for code blocks

/// A view that renders markdown with proper code block styling.
/// Use this instead of Text.markdown() when code blocks need copy buttons.
struct MarkdownTextView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(md):
                    if let attr = try? AttributedString(markdown: md) {
                        Text(attr).font(.system(size: 13)).textSelection(.enabled)
                    } else {
                        Text(md).font(.system(size: 13)).textSelection(.enabled)
                    }
                case let .code(code, _):
                    CodeBlockView(code: code)
                }
            }
        }
    }

    private enum Block {
        case text(String)
        case code(String, String?) // code, language
    }

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        var currentText = ""
        var inCode = false
        var codeContent = ""
        var codeLang: String?

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    // End code block
                    blocks.append(.code(codeContent.trimmingCharacters(in: .newlines), codeLang))
                    codeContent = ""
                    codeLang = nil
                    inCode = false
                } else {
                    // Start code block
                    if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    }
                    currentText = ""
                    codeLang = line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    if codeLang?.isEmpty == true { codeLang = nil }
                    inCode = true
                }
            } else if inCode {
                codeContent += line + "\n"
            } else {
                currentText += line + "\n"
            }
        }

        if inCode {
            blocks.append(.code(codeContent.trimmingCharacters(in: .newlines), codeLang))
        }
        if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
        }

        return blocks
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .background(Color(nsColor: .controlColor).opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .controlColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
