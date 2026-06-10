import Foundation

/// AST-level markdown sanitizer. Works on already-parsed MarkdownBlock arrays.
/// Replaces the fragile regex-based AIOutputSanitizer.cleanCodeBlocks().
enum MarkdownSanitizer {

    /// Sanitize a parsed markdown block array.
    /// Removes empty blocks, cleans code blocks, merges orphaned fragments.
    static func sanitize(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []

        for block in blocks {
            switch block {
            case let .code(code, lang):
                let cleaned = cleanCodeBlock(code)
                if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.code(cleaned, lang))
                }

            case let .paragraph(text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empty paragraphs
                if trimmed.isEmpty { continue }
                // Skip orphaned numbering (e.g., "1.", "**1. **", "2.")
                if isOrphanedNumbering(trimmed) { continue }
                result.append(.paragraph(text: text))

            case let .heading(level, text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(.heading(level: level, text: text))
                }

            case let .bulletList(items):
                let filtered = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !filtered.isEmpty {
                    result.append(.bulletList(filtered))
                }

            case let .numberedList(items):
                let filtered = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !filtered.isEmpty {
                    result.append(.numberedList(filtered))
                }

            case let .blockquote(text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.blockquote(text))
                }

            case .divider:
                result.append(.divider)
            }
        }

        return result
    }

    // MARK: - Code Block Cleaning

    /// Clean a code block's content:
    /// - Remove bare `#` lines
    /// - Remove `# SectionHeader` lines (uppercase first word)
    /// - Remove standalone numbered list items (`1. command`)
    /// - Remove trailing empty `#` comments
    /// - Collapse consecutive empty lines
    private static func cleanCodeBlock(_ code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if trimmed.isEmpty { continue }

            // Skip bare #
            if trimmed == "#" { continue }

            // Skip # SectionHeader (uppercase first word, no code indicators)
            if trimmed.hasPrefix("# ") {
                let afterHash = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if afterHash.isEmpty { continue }
                if let first = afterHash.first, first.isUppercase,
                   !afterHash.contains("="), !afterHash.contains("-"),
                   !afterHash.contains("$"), !afterHash.contains("!"),
                   !afterHash.contains("/")
                { continue }
            }

            // Skip standalone numbered list items (e.g., "1. docker pull")
            if trimmed.range(of: #"^\d+\.\s*\S"#, options: .regularExpression) != nil {
                continue
            }

            // Remove trailing empty # comment
            if let hashIndex = line.lastIndex(of: "#") {
                let afterHash = line[line.index(after: hashIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                if afterHash.isEmpty {
                    let cleaned = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty {
                        result.append(cleaned)
                        continue
                    }
                }
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Check if text is an orphaned numbering (e.g., "1.", "**1. **", "2.")
    private static func isOrphanedNumbering(_ text: String) -> Bool {
        let pattern = #"^(?:\*\*)?\d+(?:\.\d+)*\.?\s*(?:\*\*)?$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
