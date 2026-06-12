//
//  BroadcastManager.swift
//  Bonk
//

import SwiftUI

/// Manages broadcast input to multiple terminal panes.
@Observable @MainActor
final class BroadcastManager {
    /// Whether broadcast mode is active.
    var isEnabled = false

    /// Set of pane IDs that receive broadcast input.
    var targetPaneIDs: Set<UUID> = []

    /// All available pane IDs.
    var allPaneIDs: [UUID] = []

    /// Toggle broadcast for a specific pane.
    func togglePane(_ id: UUID) {
        if targetPaneIDs.contains(id) {
            targetPaneIDs.remove(id)
        } else {
            targetPaneIDs.insert(id)
        }
    }

    /// Select all panes for broadcast.
    func selectAll() {
        targetPaneIDs = Set(allPaneIDs)
    }

    /// Deselect all panes.
    func deselectAll() {
        targetPaneIDs = []
    }

    /// Toggle broadcast mode on/off.
    func toggle() {
        isEnabled.toggle()
        if !isEnabled {
            targetPaneIDs = []
        }
    }

    /// Check if a pane is a broadcast target.
    func isTarget(_ id: UUID) -> Bool {
        isEnabled && targetPaneIDs.contains(id)
    }
}
