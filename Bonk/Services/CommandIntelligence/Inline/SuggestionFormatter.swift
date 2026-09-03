//  SuggestionFormatter.swift
//  Bonk
//
//  Centralized display/normalize logic for ghost text.
//  Consolidates InlineCompletionService + SuggestionEngine variants for single source of truth.
//  P0: for parity, delegates to InlineCompletionService's proven logic.
//

import Foundation

enum SuggestionFormatter {
    /// Ghost display text — what the overlay draws.
    static func displaySuffix(_ raw: String, typed: String) -> String {
        InlineCompletionService.displaySuffix(raw, typed: typed)
    }

    /// Suffix extracted from model raw output (echo stripping).
    static func suggestionSuffix(from raw: String, typed: String) -> String {
        InlineCompletionService.suggestionSuffix(from: raw, typed: typed)
    }

    /// Normalize model raw to single line, no markdown, no prompt leftovers.
    static func normalize(_ raw: String) -> String {
        InlineCompletionService.normalize(raw)
    }

    /// Preserve leading separator (space) handling.
    static func preserveLeadingSeparator(_ raw: String) -> String {
        // Delegates to InlineCompletionService's internal logic via display path
        // For test parity, reuse same trimming semantics.
        var text = raw.trimmingCharacters(in: .newlines)
        while text.last?.isWhitespace == true { text.removeLast() }
        let hasLeading = text.first?.isWhitespace == true
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return hasLeading ? " " + text : text
    }
}
