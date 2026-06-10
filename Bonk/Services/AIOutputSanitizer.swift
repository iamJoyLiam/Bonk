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

    /// Clean up code blocks in AI output:
    /// - Remove empty `#` comment lines (just `#` with nothing after)
    /// - Remove `# SectionHeader` lines that aren't real comments
    /// - Remove empty lines between commands in code blocks
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
                // Skip empty # lines
                if trimmed == "#" { continue }
                // Skip # followed by a capitalized word (likely a section header like "# Docker")
                if trimmed.hasPrefix("# "), trimmed.count > 2 {
                    let afterHash = String(trimmed.dropFirst(2))
                    // If it starts with uppercase and has no = or - (not a real comment), skip it
                    if let first = afterHash.first, first.isUppercase,
                       !afterHash.contains("="), !afterHash.contains("-"),
                       !afterHash.contains("$"), !afterHash.contains("!")
                    { continue }
                }
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }
}
