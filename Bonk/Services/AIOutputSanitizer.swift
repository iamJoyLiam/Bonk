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
}
