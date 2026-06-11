import SwiftUI

// MARK: - Safe Markdown Helper

/// Safely parse markdown text to AttributedString. Falls back to plain text.
func markdownText(_ content: String) -> Text {
    if let attr = try? AttributedString(markdown: content) { return Text(attr) }
    return Text(content)
}

// MARK: - Simple Text Extension (for backward compatibility)

extension Text {
    /// Render text with basic markdown support. Falls back to plain text on failure.
    static func markdown(_ content: String) -> Text {
        if let attr = try? AttributedString(markdown: content) { return Text(attr) }
        return Text(content)
    }
}

// MARK: - Markdown Block Types

enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case code(String, String?) // code, language
    case bulletList([String])
    case numberedList([String])
    case blockquote(String)
    case divider

    var id: String {
        switch self {
        case let .heading(level, text): "h\(level)-\(text.prefix(20))"
        case let .paragraph(text): "p-\(text.prefix(20))"
        case let .code(code, _): "code-\(code.prefix(20))"
        case let .bulletList(items): "ul-\(items.count)"
        case let .numberedList(items): "ol-\(items.count)"
        case let .blockquote(text): "q-\(text.prefix(20))"
        case .divider: "hr"
        }
    }
}

// MARK: - Markdown Parser

enum MarkdownParser {
    static func parse(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                blocks.append(.code(code, lang.isEmpty ? nil : lang))
                i += 1 // skip closing ```
                continue
            }

            // Heading
            if line.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: String(line.dropFirst(2))))
                i += 1; continue
            }
            if line.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: String(line.dropFirst(3))))
                i += 1; continue
            }
            if line.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: String(line.dropFirst(4))))
                i += 1; continue
            }

            // Divider
            if line.trimmingCharacters(in: .whitespaces) == "---"
                || line.trimmingCharacters(in: .whitespaces) == "***"
                || line.trimmingCharacters(in: .whitespaces) == "___"
            {
                blocks.append(.divider)
                i += 1; continue
            }

            // Blockquote
            if line.hasPrefix("> ") {
                var quoteLines = [String(line.dropFirst(2))]
                i += 1
                while i < lines.count, lines[i].hasPrefix("> ") {
                    quoteLines.append(String(lines[i].dropFirst(2)))
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Bullet list
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var items = [String(line.dropFirst(2))]
                i += 1
                while i < lines.count, lines[i].hasPrefix("- ") || lines[i].hasPrefix("* ") {
                    items.append(String(lines[i].dropFirst(2)))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list
            let numberPattern = #"^\d+\.\s"#
            if line.range(of: numberPattern, options: .regularExpression) != nil {
                var items = [String(line.drop(while: { $0.isNumber || $0 == "." || $0 == " " }))]
                i += 1
                while i < lines.count, lines[i].range(of: numberPattern, options: .regularExpression) != nil {
                    items.append(String(lines[i].drop(while: { $0.isNumber || $0 == "." || $0 == " " })))
                    i += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Empty line — skip
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1; continue
            }

            // Paragraph — collect consecutive non-empty lines
            var paraLines = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty
                    || next.hasPrefix("# ")
                    || next.hasPrefix("## ")
                    || next.hasPrefix("### ")
                    || next.hasPrefix("```")
                    || next.hasPrefix("> ")
                    || next.hasPrefix("- ")
                    || next.hasPrefix("* ")
                    || next.range(of: numberPattern, options: .regularExpression) != nil
                    || next.trimmingCharacters(in: .whitespaces) == "---"
                { break }
                paraLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(text: paraLines.joined(separator: "\n")))
        }

        return blocks
    }
}

// MARK: - Rich Markdown View

struct MarkdownTextView: View {
    let content: String
    var onExecute: ((String) -> Void)?
    var sshService: SSHNetworkService?
    @State private var cachedBlocks: [MarkdownBlock] = []
    @State private var lastParsedLength: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cachedBlocks) { block in
                blockView(block)
            }
        }
        .onChange(of: content.count) { _, newCount in
            if newCount < lastParsedLength || newCount - lastParsedLength > 50 || lastParsedLength == 0 {
                cachedBlocks = MarkdownSanitizer.sanitize(MarkdownParser.parse(content))
                lastParsedLength = newCount
            }
        }
        .onAppear {
            cachedBlocks = MarkdownSanitizer.sanitize(MarkdownParser.parse(content))
            lastParsedLength = content.count
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            let size: CGFloat = level == 1 ? 18 : level == 2 ? 15 : 13
            let weight: Font.Weight = level <= 2 ? .bold : .semibold
            markdownText(text)
                .font(.system(size: size, weight: weight))
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 4 : 2)

        case let .paragraph(text):
            markdownText(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .lineSpacing(2)

        case let .code(code, lang):
            if let ssh = sshService {
                InteractiveCodeBlock(code: code, language: lang, sshService: ssh)
            } else {
                CodeBlockView(code: code, language: lang, onExecute: onExecute)
            }

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.system(size: 13)).foregroundStyle(.secondary)
                        markdownText(item)
                            .font(.system(size: 13)).textSelection(.enabled)
                    }
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        markdownText(item)
                            .font(.system(size: 13)).textSelection(.enabled)
                    }
                }
            }

        case let .blockquote(text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3)
                markdownText(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .divider:
            Divider().padding(.vertical, 4)
        }
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    var language: String?
    var onExecute: ((String) -> Void)?
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
                if let onExecute {
                    Button { onExecute(code) } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Execute command")
                }
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
