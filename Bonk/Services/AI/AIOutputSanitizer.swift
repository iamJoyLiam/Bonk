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
}
