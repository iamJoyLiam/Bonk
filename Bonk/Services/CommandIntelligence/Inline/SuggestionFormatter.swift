//  SuggestionFormatter.swift
//  Bonk
//
//  Centralized display/normalize logic for ghost text.
//  Consolidates InlineCompletionService + SuggestionEngine variants for single source of truth.
//  P0: for parity, delegates to InlineCompletionService's proven logic.
//

import Foundation

enum SuggestionFormatter {
    static let maxSuggestionChars = 200
    static let maxSuggestionTokens = 200

    /// Ghost display text — what the overlay draws.
    static func displaySuffix(_ raw: String, typed: String) -> String {
        let suffix = preserveLeadingSeparator(raw)
        guard !suffix.isEmpty else { return "" }
        let hasExplicitSeparator = suffix.first?.isWhitespace == true
        let core = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return "" }
        if hasExplicitSeparator || typed.last?.isWhitespace == true {
            return hasExplicitSeparator ? " " + core : core
        }
        if shouldInsertTokenSeparator(typed: typed, suffix: core) {
            return " " + core
        }
        return core
    }

    /// Suffix extracted from model raw output (echo stripping).
    static func suggestionSuffix(from raw: String, typed: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let text = firstLine.trimmingCharacters(in: .newlines)
        var overlap = 0
        let maxOverlap = min(typed.count, text.count)
        if maxOverlap > 0 {
            for length in stride(from: maxOverlap, through: 1, by: -1) where text.hasPrefix(typed.suffix(length)) {
                overlap = length
                break
            }
        }
        let suffix = overlap > 0 ? String(text.dropFirst(overlap)) : text
        return preserveLeadingSeparator(suffix)
    }

    /// Normalize model raw to single line, no markdown, no prompt leftovers.
    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // Strip fenced code blocks if model wrapped the suggestion
        if text.contains("```") {
            let parts = text.components(separatedBy: "```")
            if parts.count >= 2 {
                let inside = parts[1].components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                let candidate = inside.isEmpty ? parts[1] : inside
                text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = text.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip inline backticks `command`
        if text.hasPrefix("`") && text.hasSuffix("`") && text.count >= 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, text.count <= maxSuggestionChars else { return "" }
        if isConversationalOrExplanatory(text) { return "" }
        if let regex = promptLeftoverRegex, regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return "" }
        return text
    }

    /// Detect natural language commentary, explanations, or thinking leaked by models.
    static func isConversationalOrExplanatory(_ text: String) -> Bool {
        let lower = text.lowercased()
        let explanatoryKeywords = [
            "the user", "user is", "typing", "likely", "looking at", "i can see",
            "i can", "we can", "based on", "in this context", "partial command",
            "shell identifier", "here is", "this command", "you can", "you should",
            "note that", "in order to", "which is", "they're", "they are", "environment based",
            "explanation:", "suggest:", "suggestion:", "output:", "command:", "assistant:"
        ]
        for keyword in explanatoryKeywords {
            if lower.contains(keyword) {
                return true
            }
        }
        if text.contains("? ") || text.contains("! ") {
            return true
        }
        var searchStart = text.startIndex
        while let range = text.range(of: ". ", range: searchStart..<text.endIndex) {
            if range.lowerBound > text.startIndex {
                let prevChar = text[text.index(before: range.lowerBound)]
                if prevChar.isLetter {
                    return true
                }
            }
            searchStart = range.upperBound
        }
        return false
    }

    /// Full command for popup display: typed prefix + insertion suffix.
    /// Collapses the double space when typed already ends with whitespace.
    static func fullCommand(typed: String, suffix: String) -> String {
        if let last = typed.last, last.isWhitespace {
            return typed + suffix.drop(while: { $0.isWhitespace })
        }
        return typed + suffix
    }

    static func preserveLeadingSeparator(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .newlines)
        while text.last?.isWhitespace == true { text.removeLast() }
        let hasLeading = text.first?.isWhitespace == true
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return hasLeading ? " " + text : text
    }

    static func commandText(from line: String) -> String? {
        guard let regex = commandTextRegex else { return nil }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { return nil }
        let group = match.range(at: 1)
        guard group.location != NSNotFound else { return nil }
        let cmd = nsLine.substring(with: group).trimmingCharacters(in: .whitespaces)
        return cmd.isEmpty ? nil : cmd
    }

    // MARK: - Private helpers

    private static let promptLeftoverRegex: NSRegularExpression? = try? NSRegularExpression(pattern: #"^[>\$#%❯➜]\s+"#)
    private static let commandTextRegex: NSRegularExpression? = try? NSRegularExpression(pattern: #"[>%$#❯➜]\s+(\S.*)$"#)

    private static func shouldInsertTokenSeparator(typed: String, suffix: String) -> Bool {
        guard typed.last?.isWhitespace == false else { return false }
        guard let first = suffix.first, first.isLetter || first.isNumber || first == "-" || first == "/" || first == "$" else { return false }
        let tokens = typed.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 1 else { return false }
        if let last = typed.last, "=/:.$~\\".contains(last) { return false }
        if typed.contains("=") { return false }
        return true
    }
}
