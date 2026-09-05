//
//  InlineKeyboardRouter.swift
//  Bonk
//
//  P0.3 Explicit Keyboard Routing and Interaction State Machine.
//  Pure function mapping (keyEvent, context) -> KeyRoutingDecision.
//

import AppKit
import Foundation

public enum KeyRoutingDecision: Equatable, Sendable {
    case passthrough(reason: String)
    case passthroughAndCancelSuggestion(reason: String)
    case passthroughAndSchedule(characters: String?)
    case accept
    case reject
    case moveSelection(delta: Int)
    case engageSelection(initialIndex: Int)
    case interceptAppShortcut(name: Notification.Name)
    case toggleSearch
    case consume(reason: String)
}

public struct InlineKeyboardRouter: Sendable {
    /// Determines whether the event represents plain text typing or backspace
    /// that should arm the completion debounce.
    public static func shouldTriggerCompletion(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> Bool {
        guard keyCode != 53 else { return false } // Esc is never typing
        guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
        if keyCode == 51 || keyCode == 117 { return true } // Backspace / Forward Delete
        return !(characters?.isEmpty ?? true)
    }

    /// Evaluates keyboard input against inline completion state.
    public static func route(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?,
        hasSuggestion: Bool,
        engagement: SuggestionEngagement,
        candidateCount: Int,
        isPopupEnabled: Bool,
        isSearchActive: Bool,
        shortcutNotification: Notification.Name?,
        isNextCandidate: Bool = false,
        isPreviousCandidate: Bool = false
    ) -> KeyRoutingDecision {
        // 1. App shortcuts override terminal keys
        if let shortcut = shortcutNotification {
            return .interceptAppShortcut(name: shortcut)
        }

        // 2. Esc closes terminal search bar if active
        if keyCode == 53, isSearchActive {
            return .toggleSearch
        }

        // 3. Enter (Return: 36, Numpad Enter: 76)
        if keyCode == 36 || keyCode == 76 {
            if hasSuggestion, engagement.isEngaged, modifiers.isEmpty {
                return .accept
            }
            if hasSuggestion {
                return .passthroughAndCancelSuggestion(reason: "enter")
            }
            return .passthrough(reason: "enter")
        }

        // 4. Tab (48) accepts suggestion if visible
        if keyCode == 48, modifiers.isEmpty, hasSuggestion {
            return .accept
        }

        // 5. Esc (53) cancels/rejects suggestion if visible
        if keyCode == 53, hasSuggestion {
            return .reject
        }

        // 6. Configured Candidate Selection Shortcuts (Default: Cmd+Down / Cmd+Up)
        if isNextCandidate {
            if hasSuggestion, isPopupEnabled, candidateCount > 1 {
                return .moveSelection(delta: 1)
            }
            // Consume shortcut when idle or single candidate to prevent sending escape sequences () to shell
            return .consume(reason: "candidate-nav-idle")
        }

        if isPreviousCandidate {
            if hasSuggestion, isPopupEnabled, candidateCount > 1 {
                return .moveSelection(delta: -1)
            }
            // Consume shortcut when idle or single candidate to prevent sending escape sequences () to shell
            return .consume(reason: "candidate-nav-idle")
        }

        // 7. Option+Down / Option+Up to engage candidate selection (legacy compatibility)
        if keyCode == 125, modifiers.contains(.option), hasSuggestion, isPopupEnabled, candidateCount > 1 {
            return .engageSelection(initialIndex: 0)
        }
        if keyCode == 126, modifiers.contains(.option), hasSuggestion, isPopupEnabled, candidateCount > 1 {
            return .engageSelection(initialIndex: candidateCount - 1)
        }

        // 8. Plain Arrow Up / Down navigation (without Cmd/Option)
        if (keyCode == 125 || keyCode == 126), modifiers.isEmpty {
            if hasSuggestion, isPopupEnabled, candidateCount > 1, engagement.isEngaged {
                if keyCode == 125 { // Down
                    return .moveSelection(delta: 1)
                } else { // Up
                    if (engagement.selectedIndex ?? 0) > 0 {
                        return .moveSelection(delta: -1)
                    } else {
                        // At top candidate, navigating up exits popup and accesses shell history
                        return .passthroughAndCancelSuggestion(reason: "history-nav")
                    }
                }
            }
            if hasSuggestion {
                // Passive mode: forward 100% to Shell for command history navigation without conflict
                return .passthroughAndCancelSuggestion(reason: "history-nav")
            }
            return .passthrough(reason: "history-nav")
        }

        // 9. Normal typing & backspace
        if shouldTriggerCompletion(keyCode: keyCode, modifiers: modifiers, characters: characters) {
            return .passthroughAndSchedule(characters: characters)
        }

        // 10. Other keys (e.g. arrows with modifiers, function keys)
        if hasSuggestion {
            return .passthroughAndCancelSuggestion(reason: "other-key")
        }

        return .passthrough(reason: "normal")
    }
}
