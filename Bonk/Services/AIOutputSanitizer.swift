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

    /// Sanitize AI output text. Strips potentially dangerous HTML/JS constructs
    /// while preserving legitimate markdown formatting.
    static func sanitize(_ text: String) -> String {
        var result = text

        // Strip dangerous HTML tags and event handlers
        for pattern in dangerousPatterns where result.lowercased().contains(pattern) {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .caseInsensitive
            )
        }

        // Strip HTML comments that could hide content
        result = result.replacingOccurrences(
            of: "<!--.*?-->",
            with: "",
            options: .regularExpression
        )

        return result
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
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Skip empty lines
                if trimmed.isEmpty { continue }

                // Skip bare # lines
                if trimmed == "#" { continue }

                // Skip # SectionHeader (uppercase first word, no code indicators)
                if trimmed.hasPrefix("# ") {
                    let afterHash = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if afterHash.isEmpty { continue } // "# " with nothing
                    if let first = afterHash.first, first.isUppercase,
                       !afterHash.contains("="), !afterHash.contains("-"),
                       !afterHash.contains("$"), !afterHash.contains("!"),
                       !afterHash.contains("/")
                    { continue }
                }

                // Skip standalone numbered list items inside code blocks (e.g., "1. docker pull")
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
            }

            result.append(line)
        }

        // Remove consecutive empty lines outside code blocks
        var deduped: [String] = []
        var lastEmpty = false
        for line in result {
            let isEmpty = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty && lastEmpty { continue }
            deduped.append(line)
            lastEmpty = isEmpty
        }

        return deduped.joined(separator: "\n")
    }
}
