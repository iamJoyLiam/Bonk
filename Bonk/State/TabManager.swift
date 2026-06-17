//
//  TabManager.swift
//  Bonk
//
//  Manages terminal tabs - creation, selection, and lifecycle.
//

import Foundation

/// Manages terminal tabs - creation, selection, and lifecycle.
@Observable @MainActor
final class TabManager {
    private(set) var tabs: [TerminalTab] = []
    var activeTabID: UUID?

    var activeTab: TerminalTab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    /// Create a new tab for a host.
    func createTab(for host: HostItem) -> TerminalTab {
        let tab = TerminalTab(hostItem: host)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    /// Select a tab by ID.
    func selectTab(_ id: UUID) {
        activeTabID = id
    }

    /// Remove a tab by ID.
    func removeTab(_ id: UUID) {
        tabs.removeAll(where: { $0.id == id })
        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
    }

    /// Get a tab by ID.
    func tab(for id: UUID) -> TerminalTab? {
        tabs.first(where: { $0.id == id })
    }

    /// Check if a tab exists.
    func hasTab(_ id: UUID) -> Bool {
        tabs.contains(where: { $0.id == id })
    }

    /// Get all tab IDs.
    var tabIDs: [UUID] {
        tabs.map { $0.id }
    }
}
