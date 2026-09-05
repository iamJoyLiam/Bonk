//  InlinePresentationPolicy.swift
//  Bonk
//
//  Decides how ranked candidates are presented to the user.
//  Separates ranking judgment from UI display judgment (show, hide, delay, popup).
//

import Foundation

enum InlinePresentationAction: Sendable, Equatable {
    case show(suggestion: Suggestion, showPopup: Bool)
    case hide
    case delay(ms: Int)
}

struct InlinePresentationPolicy: Sendable {
    /// Minimum characters in input before allowing generative ghost to show alone without local confirmation.
    static let minGenerativeStandaloneChars = 3

    static func evaluate(
        ranked: [CommandCandidate],
        inputBuffer: String,
        isTypingFast: Bool = false
    ) -> InlinePresentationAction {
        guard let top = ranked.first, !top.suggestion.text.isEmpty else {
            return .hide
        }

        let trimmed = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Single character root command with multiple candidates:
        // When typing fast (< 160ms interval), delay 350ms to prevent popup jitter during continuous typing
        if trimmed.count == 1 && ranked.count > 1 && isTypingFast {
            return .delay(ms: 350)
        }

        // 2. If top candidate is deterministic, always display immediately
        if top.authority == .deterministic {
            let showPopup = ranked.count > 1
            return .show(suggestion: top.suggestion, showPopup: showPopup)
        }

        // 2. If top candidate is contextual (e.g. filename in cwd)
        if top.authority == .contextual {
            let showPopup = ranked.count > 1
            return .show(suggestion: top.suggestion, showPopup: showPopup)
        }

        // 3. If top is generative (LLM only):
        // If user is typing rapidly, delay presentation to avoid ghost flicker
        if isTypingFast {
            return .delay(ms: 120)
        }

        // If input is too short (< minGenerativeStandaloneChars) and no local candidate corroborated it, hide ghost.
        // Natural language intent (# or CJK) is allowed with >= 2 characters.
        let isNaturalLanguage = trimmed.hasPrefix("#") || InlineTriggerPolicy.isNaturalLanguageIntent(trimmed)
        let minChars = isNaturalLanguage ? 2 : minGenerativeStandaloneChars
        if trimmed.count < minChars {
            return .hide
        }

        // Valid standalone generative candidate
        let showPopup = ranked.count > 1
        return .show(suggestion: top.suggestion, showPopup: showPopup)
    }
}
