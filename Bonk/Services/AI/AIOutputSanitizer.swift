import Foundation

/// Sanitizes AI output to prevent rendering of malicious content.
enum AIOutputSanitizer {
    /// Patterns that should be stripped from AI output.
    private static let dangerousPatterns: [String] = [
        "<script",
        "</script",
        "javascript:",
        "onclick",
        "onerror",
        "onload",
        "onmouseover",
        "<iframe",
        "<object",
        "<embed",
        "<form",
        "<input",
        "data:text/html",
        "vbscript:",
        "expression(",
    ]

    /// Sanitize AI output text.
    /// Security filtering (HTML/JS) applies to the full text.
    /// Code block cleaning only applies INSIDE fenced code blocks,
    /// leaving outside text (lists, paragraphs) completely untouched.
    static func sanitize(_ text: String) -> String {
        // Step 1: Security filtering on full text (safe — only strips HTML/JS patterns)
        var result = text
        for pattern in dangerousPatterns where result.lowercased().contains(pattern) {
            result = result.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }
        result = result.replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)

        // Step 2: Clean code blocks only — leave outside text untouched
        let components = result.components(separatedBy: "```")
        var processed: [String] = []

        for (index, component) in components.enumerated() {
            if index % 2 != 0 {
                // Odd index = inside code block → clean it
                processed.append(cleanCodeBlockContent(component))
            } else {
                // Even index = outside code block → preserve as-is
                processed.append(component)
            }
        }

        return processed.joined(separator: "```")
    }

    /// Clean only the content INSIDE a fenced code block.
    private static func cleanCodeBlockContent(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip bare # lines
            if trimmed == "#" { continue }

            // Skip standalone numbered list items (e.g., "1. docker pull")
            if trimmed.range(of: #"^\d+\.\s*\S"#, options: .regularExpression) != nil {
                continue
            }

            // Remove trailing empty # comment (e.g., "docker images # " → "docker images")
            if let hashIndex = line.lastIndex(of: "#") {
                let afterHash = line[line.index(after: hashIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                if afterHash.isEmpty {
                    let cleaned = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty { result.append(cleaned); continue }
                }
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    /// Check if output contains potentially dangerous content.
    static func containsDangerousContent(_ text: String) -> Bool {
        let lower = text.lowercased()
        return dangerousPatterns.contains { lower.contains($0) }
    }

    /// Clean up code blocks in AI output.
    static func cleanCodeBlocks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var result: [String] = []

        for line in lines {
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                result.append(line)
                continue
            }

            if inCodeBlock {
                if let cleaned = cleanCodeBlockLine(line) {
                    result.append(cleaned)
                }
            } else {
                result.append(line)
            }
        }

        return removeConsecutiveEmptyLines(result)
    }

    /// Clean a single line inside a code block. Returns nil if line should be skipped.
    private static func cleanCodeBlockLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Skip empty lines and bare # lines
        if trimmed.isEmpty || trimmed == "#" { return nil }

        // Skip section headers (e.g., "# Section Title")
        if isSectionHeader(trimmed) { return nil }

        // Skip standalone numbered list items (e.g., "1. docker pull")
        if isNumberedListItem(trimmed) { return nil }

        // Remove trailing empty # comment
        if let cleaned = removeTrailingComment(line) {
            return cleaned
        }

        return line
    }

    /// Check if line is a section header (e.g., "# Section Title")
    private static func isSectionHeader(_ line: String) -> Bool {
        guard line.hasPrefix("# ") else { return false }
        let afterHash = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !afterHash.isEmpty else { return true }

        guard let first = afterHash.first, first.isUppercase else { return false }
        let codeIndicators: [Character] = ["=", "-", "$", "!", "/"]
        return !codeIndicators.contains(where: { afterHash.contains($0) })
    }

    /// Check if line is a numbered list item (e.g., "1. docker pull")
    private static func isNumberedListItem(_ line: String) -> Bool {
        line.range(of: #"^\d+\.\s*\S"#, options: .regularExpression) != nil
    }

    /// Remove trailing empty comment (e.g., "docker images # " → "docker images")
    private static func removeTrailingComment(_ line: String) -> String? {
        guard let hashIndex = line.lastIndex(of: "#") else { return nil }
        let afterHash = line[line.index(after: hashIndex)...]
            .trimmingCharacters(in: .whitespaces)
        guard afterHash.isEmpty else { return nil }

        let cleaned = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Remove consecutive empty lines
    private static func removeConsecutiveEmptyLines(_ lines: [String]) -> String {
        var deduped: [String] = []
        var lastEmpty = false

        for line in lines {
            let isEmpty = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty, lastEmpty { continue }
            deduped.append(line)
            lastEmpty = isEmpty
        }

        return deduped.joined(separator: "\n")
    }
}
