//  LLMCompletionAdapter.swift
//  Bonk
//
//  Strict validation and sanitization adapter for LLM inline completion outputs.
//  Rejects ~80% of invalid, conversational, or malformed LLM completions before
//  they can enter the presentation pipeline.
//

import Foundation

struct LLMCompletionAdapter: Sendable {
    /// Adapts raw LLM output into a validated Suggestion, or nil if rejected.
    static func adapt(rawOutput: String, typed: String) -> Suggestion? {
        let trimmedTyped = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmedTyped.isEmpty else { return nil }

        // Preserve whether rawOutput had an intentional leading space before cleaning
        let hadLeadingSpace = rawOutput.hasPrefix(" ")

        // 1. Strip reasoning tags (<think>...</think>)
        var cleaned = stripReasoningTags(rawOutput)
        guard !cleaned.isEmpty else { return nil }

        // 2. Reject if conversational chatter or explanatory sentences are detected
        guard !SuggestionFormatter.isConversationalOrExplanatory(cleaned) else {
            return nil
        }

        // 3. Strip markdown blocks, code fences, inline backticks
        cleaned = stripMarkdown(cleaned)
        guard !cleaned.isEmpty else { return nil }

        // 4. Strip single-line newline/carriage returns
        if let newline = cleaned.firstIndex(where: { $0.isNewline }) {
            cleaned = String(cleaned[..<newline]).trimmingCharacters(in: .whitespaces)
        }
        guard !cleaned.isEmpty else { return nil }

        // 5. Length sanity check (<= maxSuggestionChars)
        guard cleaned.count <= SuggestionFormatter.maxSuggestionChars else { return nil }

        // 6. Extract candidate continuation suffix
        var suffix = SuggestionFormatter.suggestionSuffix(from: cleaned, typed: trimmedTyped)
        guard !suffix.isEmpty else { return nil }

        // Restore intentional leading space if rawOutput had it and suffix lost it
        if hadLeadingSpace && !suffix.hasPrefix(" ") {
            suffix = " " + suffix
        }

        // 7. Validate continuation relationship with typed text:
        // If cleaned was a full command, it must start with typed (case-insensitive)
        if cleaned.lowercased().contains(" ") && !cleaned.lowercased().hasPrefix(trimmedTyped.lowercased()) {
            let lastToken = trimmedTyped.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? trimmedTyped
            let hasTokenContinuation = cleaned.lowercased().hasPrefix(lastToken.lowercased())
            if !hasTokenContinuation && !suffix.hasPrefix(" ") {
                return nil
            }
        }

        // 8. Reject single character completions that are not flags (e.g. random single letters like "e" or "r")
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespaces)
        if trimmedSuffix.count <= 1 && !trimmedSuffix.hasPrefix("-") {
            return nil
        }

        // 9. Validate Shell Fragment continuation
        guard isValidShellFragment(suffix: suffix, typed: trimmedTyped) else {
            return nil
        }

        let display = SuggestionFormatter.displaySuffix(suffix, typed: typed)
        return Suggestion(text: suffix, displayText: display)
    }

    /// Adapts raw LLM output into a validated Suggestion for natural language intent translation.
    /// Returns nil if output is invalid, conversational, or empty.
    static func adaptNaturalLanguage(rawOutput: String, typed: String) -> Suggestion? {
        let trimmedTyped = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmedTyped.isEmpty else { return nil }

        // 1. Strip reasoning tags (<think>...</think>)
        var cleaned = stripReasoningTags(rawOutput)
        guard !cleaned.isEmpty else { return nil }

        // 2. Reject if conversational chatter or explanatory sentences are detected
        guard !SuggestionFormatter.isConversationalOrExplanatory(cleaned) else {
            return nil
        }

        // 3. Strip markdown blocks, code fences, inline backticks, leading prompts
        cleaned = stripMarkdown(cleaned)
        guard !cleaned.isEmpty else { return nil }

        // 4. Strip leading '#' or comment indicators if the model repeated them
        if cleaned.hasPrefix("#") {
            cleaned = String(cleaned.drop(while: { $0 == "#" || $0.isWhitespace }))
        }
        guard !cleaned.isEmpty else { return nil }

        // 5. Take the first non-empty line
        if let firstLine = cleaned.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            cleaned = firstLine.trimmingCharacters(in: .whitespaces)
        }
        guard !cleaned.isEmpty else { return nil }

        // 6. Length sanity check (shell commands should typically be <= 200 chars)
        guard cleaned.count <= 200 else { return nil }

        // 7. Make sure it doesn't just repeat the user's natural language input
        let cleanTypedQuery = typed.hasPrefix("#") ? String(typed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmedTyped
        if cleaned.lowercased() == cleanTypedQuery.lowercased() {
            return nil
        }

        // 8. Construct Suggestion:
        // When accepted, typed is erased by sending DEL (\u{7F}) for typed.count times, followed by the command.
        let backspaces = String(repeating: "\u{7F}", count: typed.count)
        let replacementText = backspaces + cleaned
        let displayText = " -> " + cleaned

        return Suggestion(
            text: replacementText,
            displayText: displayText,
            fullText: cleaned
        )
    }

    /// Strips `<think>...</think>` and unclosed `<think>...` blocks.
    static func stripReasoningTags(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                // Unclosed think tag: strip everything from <think> to end
                result.removeSubrange(start.lowerBound..<result.endIndex)
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips markdown fences, quotes, leading prompts
    static func stripMarkdown(_ text: String) -> String {
        var result = text
        if result.contains("```") {
            let parts = result.components(separatedBy: "```")
            if parts.count >= 2 {
                let inside = parts[1].components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                result = inside.isEmpty ? parts[1] : inside
            } else {
                result = result.replacingOccurrences(of: "```", with: "")
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("`") && result.hasSuffix("`") && result.count >= 2 {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Remove common prompt prefixes like "$ ", "> ", "# "
        if result.hasPrefix("$ ") { result = String(result.dropFirst(2)) }
        if result.hasPrefix("> ") { result = String(result.dropFirst(2)) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validates that suffix forms a plausible shell fragment
    static func isValidShellFragment(suffix: String, typed: String) -> Bool {
        // Must not contain conversational punctuation like sentence period, question mark, colon
        if suffix.contains(":") || suffix.contains("?") || suffix.contains(";") || suffix.contains("!") {
            return false
        }
        // Sentence-level full stop not allowed (paths like ./file, standalone "." or .bashrc are fine, but "word. word" is conversational)
        var searchStart = suffix.startIndex
        while let range = suffix.range(of: ". ", range: searchStart..<suffix.endIndex) {
            if range.lowerBound > suffix.startIndex {
                let prevChar = suffix[suffix.index(before: range.lowerBound)]
                if prevChar.isLetter {
                    return false
                }
            }
            searchStart = range.upperBound
        }
        // If suffix does not start with space, the combined token must be continuation of last token
        if !suffix.hasPrefix(" ") {
            guard let lastCharOfTyped = typed.last, !lastCharOfTyped.isWhitespace else {
                return false
            }
        }
        return true
    }
}
