//  SuggestionEngagement.swift
//  Bonk
//
//  Engagement state machine for inline completions (P0.1 Contract).
//  Distinguishes passive suggestion display from active user keyboard selection.
//

import Foundation

/// State of user interaction with inline suggestions.
/// Engagement is the sole basis for keyboard selection and Enter interception.
public enum SuggestionEngagement: Equatable, Sendable {
    /// Suggestion/popup is visible, but user has NOT performed keyboard navigation.
    /// Enter MUST NOT accept the suggestion; it must pass through to the shell.
    case passive

    /// User explicitly pressed ↑ or ↓ to navigate candidates.
    /// Enter and Tab will accept the chosen candidate at `index`.
    case engaged(index: Int)

    public var isEngaged: Bool {
        switch self {
        case .passive: return false
        case .engaged: return true
        }
    }

    public var selectedIndex: Int? {
        switch self {
        case .passive: return nil
        case .engaged(let idx): return idx
        }
    }
}

/// Comprehensive inline completion state combining candidate availability and engagement.
public enum InlineCompletionState: Equatable, Sendable {
    case normal
    case passive(candidates: [String])
    case engaged(candidates: [String], selectedIndex: Int)

    public var isEngaged: Bool {
        if case .engaged = self { return true }
        return false
    }

    public var candidates: [String] {
        switch self {
        case .normal: return []
        case .passive(let list), .engaged(let list, _): return list
        }
    }

    public var selectedIndex: Int? {
        switch self {
        case .normal, .passive: return nil
        case .engaged(_, let idx): return idx
        }
    }
}
