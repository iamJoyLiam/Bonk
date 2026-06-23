//
//  SessionManager+SplitPane.swift
//  Bonk
//
//  Split pane operations for SessionManager.
//

import Foundation

extension SessionManager {
    // MARK: - Split Pane

    /// Split the active pane horizontally (left-right).
    func splitHorizontal() {
        guard let tab = activeTab else { return }
        let newPane = tab.layout.splitHorizontal()
        tab.activePaneID = newPane.id
        FocusManager.shared.focus(newPane.id)
        updateTabTitleForSplit(tab)

        Task { await connectPane(tab: tab, pane: newPane) }
    }

    /// Split the active pane vertically (top-bottom).
    func splitVertical() {
        guard let tab = activeTab else { return }
        let newPane = tab.layout.splitVertical()
        tab.activePaneID = newPane.id
        FocusManager.shared.focus(newPane.id)
        updateTabTitleForSplit(tab)

        Task { await connectPane(tab: tab, pane: newPane) }
    }

    /// Update tab title to indicate split state.
    func updateTabTitleForSplit(_ tab: TerminalTab) {
        let paneCount = tab.layout.root.paneCount
        if paneCount > 1 {
            tab.title = "Workspace"
        } else {
            tab.title = tab.hostItem.name
        }
    }

    /// Link target pane to source pane's PTY session (shared view mode).
    func linkPanes(sourceID: UUID, targetID: UUID, in tab: TerminalTab) {
        guard let sourcePane = tab.layout.findPane(id: sourceID),
              let targetPane = tab.layout.findPane(id: targetID) else { return }
        targetPane.sessionMode = .linked(sourcePaneID: sourceID)
        targetPane.ptySession = sourcePane.ptySession
    }

    /// Unlink a pane (restore independent mode).
    func unlinkPane(_ paneID: UUID, in tab: TerminalTab) {
        guard let pane = tab.layout.findPane(id: paneID) else { return }
        if case .linked = pane.sessionMode {
            pane.sessionMode = .independent
            pane.ptySession = nil
            // Open new PTY for the unlinked pane
            Task { await openPTYForPane(tab: tab, pane: pane) }
        }
    }

    /// Open a new PTY session for a pane.
    func openPTYForPane(tab: TerminalTab, pane: PaneState) async {
        guard let service = tab.session?.sshService else { return }
        do {
            let ptySession = try await service.openPTY()
            pane.ptySession = ptySession
        } catch {
            Log.session.error("[SPLIT] Failed to open PTY: \(error.localizedDescription)")
        }
    }

    /// Close the active pane in the active tab.
    func closePane() {
        guard let tab = activeTab, let paneID = tab.activePaneID else { return }
        // Don't close if it's the last pane
        guard tab.layout.root.paneCount > 1 else { return }

        if tab.layout.closeActivePane() {
            // Close the PTY session for the closed pane
            if let pane = tab.layout.findPane(id: paneID) {
                pane.ptySession?.close()
            }
            // Clean up the closed pane
            viewCache.remove(paneID)
            // Update active pane
            tab.activePaneID = tab.layout.activePaneID
            // Update tab title
            updateTabTitleForSplit(tab)
        }
    }

    /// Close a specific pane in a tab.
    func closePane(_ paneID: UUID, in tab: TerminalTab) {
        // Don't close if it's the last pane
        guard tab.layout.root.paneCount > 1 else { return }

        if tab.layout.closePane(id: paneID) {
            // Close the PTY session for the closed pane
            // Note: findPane won't work after removal, so we need to close before
            // The pane's PTY session should be closed by the caller or here
            // Clean up the closed pane
            viewCache.remove(paneID)
            // Update active pane if needed
            if tab.activePaneID == paneID {
                tab.activePaneID = tab.layout.activePaneID
            }
            // Update tab title
            updateTabTitleForSplit(tab)
        }
    }

    /// Unsplit a pane: move it to a new tab instead of closing it.
    /// The new tab reuses the existing SSH connection and PTY session (preserves history).
    func unsplitPane(_ paneID: UUID, from tab: TerminalTab) {
        // Don't unsplit if it's the only pane
        guard tab.layout.root.paneCount > 1 else { return }

        // Find the pane to unsplit
        guard let pane = tab.layout.findPane(id: paneID) else { return }

        // Get the PTY session before removing
        guard let ptySession = pane.ptySession else {
            // If no PTY session, just close the pane
            closePane(paneID, in: tab)
            return
        }

        // Get the pane's title for the new tab
        // Always use sourceHostItem name if available (from drag-to-split)
        // Otherwise, use pane's title or tab's hostItem name
        let paneTitle: String = if let sourceHostItem = tab.sourceHostItem {
            sourceHostItem.name
        } else if !pane.title.isEmpty {
            pane.title
        } else {
            tab.hostItem.name
        }

        // Create a new tab for this pane with the source hostItem
        // Always use sourceHostItem if available, otherwise use tab's hostItem
        let newTab = TerminalTab(hostItem: tab.sourceHostItem ?? tab.hostItem)
        newTab.title = paneTitle // Use pane's title (e.g., "195")

        // Insert the new tab based on pane position
        // Find the pane's position in the layout to determine where to insert the new tab
        let allPaneIDs = tab.layout.root.allPaneIDs
        let paneIndex = allPaneIDs.firstIndex(of: paneID) ?? 0
        let isLastPane = paneIndex == allPaneIDs.count - 1

        if let tabIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
            if isLastPane {
                // If it's the last pane, insert after the original tab
                tabs.insert(newTab, at: tabIndex + 1)
            } else {
                // If it's not the last pane, insert before the original tab
                tabs.insert(newTab, at: tabIndex)
            }
        } else {
            tabs.append(newTab)
        }

        // Create a new session for the new tab, reusing the SSH connection
        let newSession = TerminalSession(tabID: newTab.id)
        newSession.sshService = tab.session?.sshService
        newSession.connectionState = .connected
        newTab.session = newSession

        // Move the PTY session to the new tab (preserves history)
        if let newPane = newTab.layout.root.paneState {
            newPane.ptySession = ptySession
        }

        // Remove the pane from the original tab (keep original tab's connection intact)
        if tab.layout.closePane(id: paneID) {
            viewCache.remove(paneID)
            // Update active pane if needed
            if tab.activePaneID == paneID {
                tab.activePaneID = tab.layout.activePaneID
            }
            // Update tab title - restore original name if only one pane left
            if tab.layout.root.paneCount <= 1 {
                // Restore the original tab title (use hostItem name, not "Workspace")
                tab.title = tab.hostItem.name
                // Clear source hostItem after unsplit
                tab.sourceHostItem = nil
            }
        }

        // Set the new tab as active
        activeTabID = newTab.id
    }

    /// Connect a new pane (open PTY session).
    func connectPane(tab: TerminalTab, pane: PaneState) async {
        guard let service = tab.session?.sshService else { return }
        do {
            let ptySession = try await service.openPTY()
            pane.ptySession = ptySession
        } catch {
            Log.session.error("[SPLIT] Failed to open PTY for new pane: \(error.localizedDescription)")
        }
    }

    /// Select a pane within the active tab.
    func selectPane(_ paneID: UUID) {
        guard let tab = activeTab else { return }
        tab.layout.selectPane(paneID)
        tab.activePaneID = paneID
    }

    /// Add a pane from source tab to target tab (for drag-to-split).
    func addPaneFromTab(_ sourceTabID: UUID, to targetTabID: UUID, position: DropPosition = .right) {
        Log.session.info("[SPLIT] addPaneFromTab: source=\(sourceTabID), target=\(targetTabID)")

        guard sourceTabID != targetTabID else {
            Log.session.warning("[SPLIT] Source and target are the same tab, ignoring")
            return
        }

        guard let sourceTab = tabs.first(where: { $0.id == sourceTabID }),
              let targetTab = tabs.first(where: { $0.id == targetTabID }) else
        {
            Log.session.warning("[SPLIT] Tab not found")
            return
        }

        guard let sourcePane = sourceTab.layout.root.paneState else {
            Log.session.warning("[SPLIT] Source tab has no pane state")
            return
        }

        guard let sourcePTY = sourcePane.ptySession else {
            Log.session.warning("[SPLIT] Source pane has no PTY session")
            return
        }

        // Create new pane based on position:
        // left/right → horizontal split; top/bottom → vertical split
        let newPane: PaneState = switch position {
        case .left, .right:
            targetTab.layout.splitHorizontal()
        case .top, .bottom:
            targetTab.layout.splitVertical()
        }

        // Set new pane title to source tab name
        newPane.title = sourceTab.hostItem.name

        // Store source hostItem for unsplit
        targetTab.sourceHostItem = sourceTab.hostItem

        // Set the target pane's title to target tab's hostItem name
        let allPaneIDs = targetTab.layout.root.allPaneIDs
        for paneID in allPaneIDs where paneID != newPane.id {
            if let targetPane = targetTab.layout.findPane(id: paneID) {
                targetPane.title = targetTab.hostItem.name
            }
        }

        // Adjust pane order based on position
        // If position is .left or .top, swap the panes so new pane is first
        if position == .left || position == .top {
            targetTab.layout.swapPanes()
        }

        // Move PTY session from source to new pane
        newPane.ptySession = sourcePTY
        sourcePane.ptySession = nil

        // Don't move terminal view cache - let the new pane create its own
        // This prevents content overlap from the old terminal
        viewCache.remove(sourcePane.id)

        // Update tab title and switch to target
        updateTabTitleForSplit(targetTab)
        activeTabID = targetTabID

        // Remove source tab (connection stays alive, PTY was moved)
        tabs.removeAll(where: { $0.id == sourceTabID })
        sessionStore.removeSession(sourceTabID)
        syncBroadcastTargets()

        Log.session.info("[SPLIT] Complete. Target tab now has \(targetTab.layout.root.paneCount) panes")
    }
}
