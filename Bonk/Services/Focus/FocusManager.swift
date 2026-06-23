//
//  FocusManager.swift
//  Bonk
//
//  Centralized focus management for split pane system.
//  Supports keyboard navigation with Cmd+Option+Arrow keys.
//

import AppKit
import Foundation

/// Navigation direction for focus movement.
enum NavigationDirection {
    case left, right, upward, downward
}

/// Manages keyboard focus across split panes.
@Observable @MainActor
final class FocusManager {
    static let shared = FocusManager()

    /// Currently focused pane ID.
    private(set) var focusedPaneID: UUID?

    private init() {}

    /// Set focus to a specific pane.
    func focus(_ paneID: UUID) {
        focusedPaneID = paneID
    }

    /// Clear focus.
    func clearFocus() {
        focusedPaneID = nil
    }

    /// Check if a pane is focused.
    func isFocused(_ paneID: UUID) -> Bool {
        focusedPaneID == paneID
    }

    /// Navigate to adjacent pane in the given direction.
    func navigate(direction: NavigationDirection, in tab: TerminalTab) {
        guard let currentID = focusedPaneID else {
            // No focus, focus first pane
            focusedPaneID = tab.layout.root.allPaneIDs.first
            return
        }

        let allPanes = tab.layout.root.allPaneIDs
        guard let currentIndex = allPanes.firstIndex(of: currentID) else { return }

        // Sequential navigation through pane IDs
        let nextIndex: Int = switch direction {
        case .right, .downward:
            (currentIndex + 1) % allPanes.count
        case .left, .upward:
            (currentIndex - 1 + allPanes.count) % allPanes.count
        }

        focusedPaneID = allPanes[nextIndex]
    }
}
