//
//  SessionManager+SplitPane.swift
//  Bonk
//
//  Split pane operations for SessionManager.
//

import Foundation
import os.log

extension SessionManager {
    // MARK: - Split Pane

    /// Adjust a split container'sessionState proportion while the user drags a divider.
    /// `normalizedDelta` is the drag movement as a fraction of the container
    /// size; `dividerIndex` selects the adjacent child pair to resize.
    func setSplitFraction(
        _ normalizedDelta: CGFloat,
        containerID: UUID,
        dividerIndex: Int,
        in tab: TerminalTab
    ) {
        tab.layout.setFraction(normalizedDelta, containerID: containerID, dividerIndex: dividerIndex)
    }

    /// Split the active pane horizontally (left-right).
    func splitHorizontal() {
        guard let tab = activeTab else { return }
        guard let newPane = tab.layout.splitHorizontal() else { return }
        tab.activePaneID = newPane.id
        TeamRelay.shared.setSharedSession(tabID: tab.id, paneID: newPane.id)
        FocusManager.shared.focus(newPane.id)
        updateTabTitleForSplit(tab)

        Task { await connectPane(tab: tab, pane: newPane) }
    }

    /// Split the active pane vertically (top-bottom).
    func splitVertical() {
        guard let tab = activeTab else { return }
        guard let newPane = tab.layout.splitVertical() else { return }
        tab.activePaneID = newPane.id
        TeamRelay.shared.setSharedSession(tabID: tab.id, paneID: newPane.id)
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

    /// Link target pane to source pane'sessionState PTY session (shared view mode).
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
            Task { await connectPane(tab: tab, pane: pane) }
        }
    }

    /// Close the active pane in the active tab.
    func closePane() {
        guard let tab = activeTab else { return }
        // The layout'sessionState activePaneID is the single source of truth; using it
        // here keeps this in sync even if tab.activePaneID drifted.
        let paneID = tab.layout.activePaneID
        // Don't close if it'sessionState the last pane
        guard tab.layout.root.paneCount > 1 else { return }

        // Capture pane reference BEFORE removing from layout tree
        guard let pane = tab.layout.findPane(id: paneID) else { return }

        if tab.layout.closePane(id: paneID) {
            // Close the PTY session for the closed pane
            pane.ptySession?.close()
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
        // Don't close if it'sessionState the last pane
        guard tab.layout.root.paneCount > 1 else { return }

        // Capture pane reference BEFORE removing from layout tree
        guard let pane = tab.layout.findPane(id: paneID) else { return }

        if tab.layout.closePane(id: paneID) {
            // Close the PTY session for the closed pane
            pane.ptySession?.close()
            // Clean up the closed pane
            viewCache.remove(paneID)
            // Keep tab.activePaneID in sync unconditionally
            tab.activePaneID = tab.layout.activePaneID
            // Update tab title
            updateTabTitleForSplit(tab)
        }
    }

    /// Unsplit a pane: move it to a new tab instead of closing it.
    /// The new tab reuses the existing SSH connection and PTY session (preserves history).
    func unsplitPane(_ paneID: UUID, from tab: TerminalTab) {
        // Don't unsplit if it'sessionState the only pane
        guard tab.layout.root.paneCount > 1 else { return }

        // Find the pane to unsplit
        guard let pane = tab.layout.findPane(id: paneID) else { return }

        // Get the PTY session before removing
        guard let ptySession = pane.ptySession else {
            // If no PTY session, just close the pane
            closePane(paneID, in: tab)
            return
        }

        // The pane'sessionState own host is the single source of truth: it was recorded when
        // the pane was moved in (drag-to-split), so unsplitting restores the
        // exact original tab. Plain split panes inherit the tab'sessionState host.
        let paneHostItem = pane.hostItem ?? tab.hostItem

        // Get the pane'sessionState title for the new tab
        let paneTitle: String = if let paneHost = pane.hostItem {
            paneHost.name
        } else if !pane.title.isEmpty {
            pane.title
        } else {
            tab.hostItem.name
        }

        // Create a new tab for this pane with the pane'sessionState own host item
        let newTab = TerminalTab(hostItem: paneHostItem)
        newTab.title = paneTitle
        if let serialConfig = tab.serialConfig {
            newTab.serialConfig = serialConfig
        }

        // Insert the new tab based on pane position
        let allPaneIDs = tab.layout.root.allPaneIDs
        let paneIndex = allPaneIDs.firstIndex(of: paneID) ?? 0
        let isLastPane = paneIndex == allPaneIDs.count - 1

        if let tabIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
            if isLastPane {
                tabs.insert(newTab, at: tabIndex + 1)
            } else {
                tabs.insert(newTab, at: tabIndex)
            }
        } else {
            tabs.append(newTab)
        }

        // Create a new session for the new tab, reusing the SSH connection
        let newSession = TerminalSession(tabID: newTab.id)
        newSession.sshService = tab.session?.sshService
        newSession.ownsSSHService = false // Shared SSH connection — don't disconnect on teardown
        newSession.connectionState = .connected
        newTab.session = newSession

        // Move the PTY session to the new tab (preserves history)
        if let newPane = newTab.layout.root.paneState {
            newPane.ptySession = ptySession
            ptySession.teamSessionID = TeamSessionID(tabID: newTab.id, paneID: newPane.id)
        }

        // Remove the pane from the original tab
        if tab.layout.closePane(id: paneID) {
            viewCache.remove(paneID)
            tab.activePaneID = tab.layout.activePaneID
            if tab.layout.root.paneCount <= 1 {
                tab.title = tab.hostItem.name
            }
        }

        // Set the new tab as active
        activeTabID = newTab.id
        if let paneID = newTab.activePaneID {
            TeamRelay.shared.setSharedSession(tabID: newTab.id, paneID: paneID)
        }
    }

    /// Connect a new pane (open PTY session).
    func connectPane(tab: TerminalTab, pane: PaneState) async {
        // Guards against the pane having been removed from the tree while the
        // connection was in flight (e.g. user closed the pane right after
        // splitting). Returns the session for cleanup instead of leaking it.
        func adoptOrClose(_ ptySession: PTYSession) {
            guard tab.layout.findPane(id: pane.id) != nil else {
                ptySession.close()
                return
            }
            pane.ptySession = ptySession
            ptySession.teamSessionID = TeamSessionID(tabID: tab.id, paneID: pane.id)
            NotificationCenter.default.post(name: .terminalPTYSessionReady, object: nil, userInfo: ["tabID": tab.id])
        }

        if let serialConfig = tab.serialConfig {
            do {
                let ptySession = try SerialPortService.shared.openSession(
                    config: serialConfig,
                    onDisconnect: { [weak tab] in
                        Task { @MainActor in
                            tab?.session?.connectionState = .disconnected
                            tab?.session?.errorMessage = "Serial port disconnected"
                        }
                    }
                )
                adoptOrClose(ptySession)
            } catch {
                Log.session.error("[SPLIT] Failed to open serial PTY: \(error.localizedDescription)")
            }
            return
        }

        // Wait for sshService to be ready (restore path races connectTab)
        var service = tab.session?.sshService
        if service == nil {
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if let sessionState = tab.session?.sshService { service = sessionState; break }
            }
        }
        guard let service else {
            Log.session.error("[SPLIT] No sshService after wait for pane \(pane.id)")
            return
        }
        do {
            let ptySession = try await service.openPTY()
            adoptOrClose(ptySession)
        } catch {
            Log.session.error("[SPLIT] Failed to open PTY for new pane: \(error.localizedDescription)")
        }
    }

    /// Select a pane within the active tab.
    func selectPane(_ paneID: UUID) {
        guard let tab = activeTab else { return }
        tab.layout.selectPane(paneID)
        tab.activePaneID = paneID
        TeamRelay.shared.setSharedSession(tabID: tab.id, paneID: paneID)
    }

    /// Add a pane from source tab to target tab (for drag-to-split).
    /// The new pane is inserted NEXT TO `targetPaneID` — the pane the user
    /// dropped onto — not beside whatever pane happens to be active.
    func addPaneFromTab(
        _ sourceTabID: UUID,
        to targetTabID: UUID,
        paneID targetPaneID: UUID,
        position: DropPosition = .right
    ) {
        Log.session.info("[SPLIT] addPaneFromTab: source=\(sourceTabID), target=\(targetTabID), pane=\(targetPaneID)")

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

        // Create new pane at the correct position based on drop location
        let direction: TabLayout.SplitDirection = position.isHorizontal ? .horizontal : .vertical
        let insertPosition: TabLayout.PaneInsertPosition = (position == .left || position == .top) ? .before : .after
        guard let newPane = targetTab.layout.insertPane(
            direction: direction,
            at: insertPosition,
            targetPaneID: targetPaneID
        ) else {
            Log.session.warning("[SPLIT] Insert failed: target pane not in target layout")
            return
        }
        // Keep tab.activePaneID in sync with the layout'sessionState single source of truth
        targetTab.activePaneID = targetTab.layout.activePaneID

        // Set new pane title to source tab name
        newPane.title = sourceTab.hostItem.name
        // Remember the pane'sessionState true host so unsplit recreates the original tab
        newPane.hostItem = sourceTab.hostItem

        // Serial config: the moved pane may come from a serial tab
        if targetTab.serialConfig == nil {
            targetTab.serialConfig = sourceTab.serialConfig
        }

        // Move PTY session from source to new pane
        newPane.ptySession = sourcePTY
        sourcePTY.teamSessionID = TeamSessionID(tabID: targetTab.id, paneID: newPane.id)
        sourcePane.ptySession = nil

        // Don't move terminal view cache
        viewCache.remove(sourcePane.id)

        // Update tab title and switch to target
        updateTabTitleForSplit(targetTab)
        activeTabID = targetTabID

        // Remove source tab
        tabs.removeAll(where: { $0.id == sourceTabID })
        sessionStore.removeSession(sourceTabID)
        syncBroadcastTargets()

        Log.session.info("[SPLIT] Complete. Target tab now has \(targetTab.layout.root.paneCount) panes")
    }
}
