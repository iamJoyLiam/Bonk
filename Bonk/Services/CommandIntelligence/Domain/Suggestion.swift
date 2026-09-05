//  Suggestion.swift
//  Bonk
//
//  Domain model for inline ghost — pure value, no logic.
//

import Foundation

struct Suggestion: Sendable, Equatable {
    let text: String          // raw suffix to insert
    let displayText: String   // ghost display (with leading space handling)
    /// Full command (typed prefix + suffix) for the candidate popup. Nil when unknown.
    let fullText: String?

    init(text: String, displayText: String, fullText: String? = nil) {
        self.text = text
        self.displayText = displayText
        self.fullText = fullText
    }

    /// Copy with the full command computed from the typed prefix (idempotent).
    func withFullCommand(typed: String) -> Suggestion {
        guard fullText == nil else { return self }
        return Suggestion(
            text: text,
            displayText: displayText,
            fullText: SuggestionFormatter.fullCommand(typed: typed, suffix: text)
        )
    }
}
