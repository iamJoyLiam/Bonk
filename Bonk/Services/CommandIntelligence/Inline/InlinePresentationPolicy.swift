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

        // 1. If top candidate is deterministic, always display immediately
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

        // If input is too short (< minGenerativeStandaloneChars) and no local candidate corroborated it, hide ghost
        let trimmed = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < minGenerativeStandaloneChars {
            return .hide
        }

        // Valid standalone generative candidate
        let showPopup = ranked.count > 1
        return .show(suggestion: top.suggestion, showPopup: showPopup)
    }
}
