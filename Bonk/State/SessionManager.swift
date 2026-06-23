import os.log
import SwiftData
import SwiftUI

/// Manages multiple concurrent SSH terminal sessions.
@Observable
@MainActor
final class SessionManager {
    /// All tabs (each tab is a workspace with its own split layout).
    private(set) var tabs: [TerminalTab] = []

    var activeTabID: UUID?

    var lastError: String?
    var showError = false
    /// Global broadcast mode (all tabs receive input).
    var isGlobalBroadcastEnabled: Bool = false
    /// Currently dragging tab ID (memory state for drag-and-drop).
    var draggingTabID: UUID?
    /// Target tab ID when dragging over a tab (for showing indicator).
    var dragTargetTabID: UUID?
    private let hostKeyStore = PersistentHostKeyStore()
    private let viewCache: TerminalViewCache
    var broadcastManager: BroadcastManager?
    private var modelContext: ModelContext?

    /// Handles input processing, command history, and broadcast.
    let inputHandler = InputHandler()

    /// Centralized session store for lifecycle management.
    let sessionStore = SessionStore.shared

    init(viewCache: TerminalViewCache = .shared) {
        self.viewCache = viewCache
    }

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    var activeTab: TerminalTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    /// The active pane state in the active tab.
    var activePane: PaneState? {
        guard let tab = activeTab, let paneID = tab.activePaneID else { return nil }
        return tab.layout.findPane(id: paneID)
    }

    // MARK: - Tab Management

    func openTab(for host: HostItem) {
        let tab = TerminalTab(hostItem: host)
        tabs.append(tab)
        activeTabID = tab.id
        syncBroadcastTargets()

        let session = sessionStore.session(for: tab)
        tab.session = session

        Task { await connectTab(tab) }
    }

    func selectTab(_ id: UUID) {
        activeTabID = id
    }

    func closeTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await disconnectTab(id)
        // Clean up all pane views
        for paneID in tab.paneIDs {
            viewCache.remove(paneID)
        }
        sessionStore.removeSession(id)
        tabs.removeAll(where: { $0.id == id })

        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
        syncBroadcastTargets()
    }

    /// Copy a tab (create a new tab with the same host).
    func copyTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let newTab = TerminalTab(hostItem: tab.hostItem)
        newTab.title = "\(tab.title) (copy)"
        tabs.append(newTab)
        activeTabID = newTab.id
        syncBroadcastTargets()

        let session = sessionStore.session(for: newTab)
        newTab.session = session
        Task { await connectTab(newTab) }
    }

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
    private func updateTabTitleForSplit(_ tab: TerminalTab) {
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
    private func openPTYForPane(tab: TerminalTab, pane: PaneState) async {
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

        // Debug: Print pane title
        Log.session.info("[UNSPLIT] Pane title: '\(pane.title)', tab hostItem name: '\(tab.hostItem.name)'")
        Log.session.info("[UNSPLIT] Source hostItem name: '\(tab.sourceHostItem?.name ?? "nil")'")

        // Get the pane's title for the new tab
        // Always use sourceHostItem name if available (from drag-to-split)
        // Otherwise, use pane's title or tab's hostItem name
        let paneTitle: String
        if let sourceHostItem = tab.sourceHostItem {
            paneTitle = sourceHostItem.name
        } else if !pane.title.isEmpty {
            paneTitle = pane.title
        } else {
            paneTitle = tab.hostItem.name
        }

        // Debug: Print final title
        Log.session.info("[UNSPLIT] Final title for new tab: '\(paneTitle)'")

        // Create a new tab for this pane with the source hostItem
        // Always use sourceHostItem if available, otherwise use tab's hostItem
        let newTab = TerminalTab(hostItem: tab.sourceHostItem ?? tab.hostItem)
        newTab.title = paneTitle  // Use pane's title (e.g., "195")

        // Insert the new tab at the same position as the original tab (left side)
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.insert(newTab, at: index)
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
                tab.title = tab.hostItem.name
                // Clear source hostItem after unsplit
                tab.sourceHostItem = nil
            }
        }

        // Set the new tab as active
        activeTabID = newTab.id
    }

    /// Connect a new pane (open PTY session).
    private func connectPane(tab: TerminalTab, pane: PaneState) async {
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
              let targetTab = tabs.first(where: { $0.id == targetTabID }) else {
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
        let newPane: PaneState
        switch position {
        case .left, .right:
            newPane = targetTab.layout.splitHorizontal()
        case .top, .bottom:
            newPane = targetTab.layout.splitVertical()
        }

        // Debug: Print source tab info
        Log.session.info("[SPLIT] Source tab ID: \(sourceTabID)")
        Log.session.info("[SPLIT] Target tab ID: \(targetTabID)")
        Log.session.info("[SPLIT] Source tab hostItem name: '\(sourceTab.hostItem.name)'")
        Log.session.info("[SPLIT] Target tab hostItem name: '\(targetTab.hostItem.name)'")
        Log.session.info("[SPLIT] New pane ID: \(newPane.id)")
        Log.session.info("[SPLIT] Position: \(position.rawValue)")

        // Set new pane title to source tab name
        newPane.title = sourceTab.hostItem.name
        Log.session.info("[SPLIT] New pane title set to: '\(newPane.title)'")

        // Store source hostItem for unsplit
        targetTab.sourceHostItem = sourceTab.hostItem

        // Set the target pane's title if it's empty
        // Find the target pane by looking for the pane that is NOT the new pane
        let allPaneIDs = targetTab.layout.root.allPaneIDs
        Log.session.info("[SPLIT] All pane IDs: \(allPaneIDs)")
        for paneID in allPaneIDs {
            if paneID != newPane.id {
                if let targetPane = targetTab.layout.findPane(id: paneID) {
                    Log.session.info("[SPLIT] Target pane ID: \(paneID)")
                    Log.session.info("[SPLIT] Target pane title before: '\(targetPane.title)'")
                    // Always set target pane title to target tab's hostItem name
                    targetPane.title = targetTab.hostItem.name
                    Log.session.info("[SPLIT] Target pane title after: '\(targetPane.title)'")
                }
            }
        }

        // Adjust pane order based on position
        // If position is .left or .top, swap the panes so new pane is first
        if position == .left || position == .top {
            // Swap the panes in the layout
            targetTab.layout.swapPanes()
            Log.session.info("[SPLIT] Swapped panes for position: \(position.rawValue)")
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

    // MARK: - Connection

    func connectTab(_ tab: TerminalTab) async {
        Log.session.info("[CONNECT] Starting connectTab for \(tab.hostItem.host):\(tab.hostItem.port)")

        guard !sessionStore.isConnecting(tab.id) else {
            Log.session.warning("[CONNECT] Already connecting to \(tab.hostItem.host), skipping")
            return
        }
        sessionStore.markConnecting(tab.id)
        defer { sessionStore.markConnected(tab.id) }

        let session = sessionStore.session(for: tab)
        tab.session = session
        session.connectionState = .connecting
        session.errorMessage = nil

        guard let config = resolveConnectionConfig(for: tab, session: session) else {
            Log.session.error("[CONNECT] Failed to resolve connection config")
            return
        }

        let service = SSHNetworkService(hostKeyStore: hostKeyStore)
        session.sshService = service
        observeStateChanges(for: tab, session: session, service: service)

        do {
            try await service.connect(config: config)

            guard tabs.contains(where: { $0.id == tab.id }) else { return }

            await service.enableReconnection(attempts: 3)

            guard tabs.contains(where: { $0.id == tab.id }) else { return }

            session.connectionState = .connected
            session.connectedAt = Date()

            EventPublisher.shared.publish(SessionEvent.connected(tabID: tab.id))

            // Connect the first pane
            if let firstPane = tab.layout.root.paneState {
                try await setupPTYSession(for: tab, pane: firstPane, session: session, service: service)
            }
            Log.session.info("[CONNECT] PTY session established successfully")
        } catch {
            Log.session.error("[CONNECT] Connection failed: \(error.localizedDescription)")
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            session.connectionState = .disconnected
            session.errorMessage = error.localizedDescription
            lastError = error.localizedDescription
            showError = true

            EventPublisher.shared.publish(SessionEvent.error(tabID: tab.id, error: error))
        }
    }

    func disconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await sessionStore.disconnect(id)
        // Close all pane PTY sessions
        for paneID in tab.paneIDs {
            tab.layout.findPane(id: paneID)?.ptySession?.close()
        }
        tab.session?.disconnect()
        tab.session = nil

        EventPublisher.shared.publish(SessionEvent.disconnected(tabID: id))
    }

    func reconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await disconnectTab(id)
        await connectTab(tab)
    }

    // MARK: - Input

    func resizePTY(cols: Int, rows: Int, tabID: UUID, paneID: UUID? = nil) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let targetPaneID = paneID ?? tab.activePaneID else { return }
        guard let pane = tab.layout.findPane(id: targetPaneID),
              let pty = pane.ptySession else { return }
        try await pty.resize(cols: cols, rows: rows)
    }

    func updateTabTitle(_ title: String, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if let cwd = parseCWD(from: title) {
            tab.currentDirectory = cwd
        }
    }

    func sendInput(_ bytes: ArraySlice<UInt8>, to tabID: UUID, paneID: UUID? = nil) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let targetPaneID = paneID ?? tab.activePaneID else { return }

        // Send to target pane
        guard let pane = tab.layout.findPane(id: targetPaneID),
              let pty = pane.ptySession else { return }
        try await pty.sendInput(bytes)

        // Broadcast to other panes if enabled
        let isGlobalBroadcast = broadcastManager?.isEnabled ?? false
        if isGlobalBroadcast {
            // Global broadcast: send to ALL panes in ALL tabs (including current tab)
            for otherTab in tabs {
                for otherPaneID in otherTab.paneIDs {
                    // Skip the target pane we already sent to
                    if otherTab.id == tabID && otherPaneID == targetPaneID { continue }
                    if let otherPane = otherTab.layout.findPane(id: otherPaneID),
                       let otherPTY = otherPane.ptySession {
                        try? await otherPTY.sendInput(bytes)
                    }
                }
            }
        } else if tab.isBroadcastEnabled {
            // Local broadcast: send to all panes in this tab only
            for otherPaneID in tab.paneIDs where otherPaneID != targetPaneID {
                if let otherPane = tab.layout.findPane(id: otherPaneID),
                   let otherPTY = otherPane.ptySession {
                    try? await otherPTY.sendInput(bytes)
                }
            }
        }
    }

    /// Convenience: send text to the active pane (auto-appends Enter).
    func sendTextToActiveTab(_ text: String) {
        guard let tab = activeTab, let paneID = tab.activePaneID else { return }
        Task {
            var bytes = Array(text.utf8)[...]
            bytes.append(13) // Enter key
            try? await sendInput(bytes, to: tab.id, paneID: paneID)
        }
    }

    /// Toggle local broadcast for a tab.
    func toggleTabBroadcast(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.isBroadcastEnabled.toggle()
    }

    /// Toggle global broadcast.
    func toggleGlobalBroadcast() {
        isGlobalBroadcastEnabled.toggle()
    }

    // MARK: - Broadcast Sync

    private func syncBroadcastTargets() {
        let allPaneIDs = tabs.flatMap { $0.paneIDs }
        broadcastManager?.allPaneIDs = allPaneIDs
        let validIDs = Set(allPaneIDs)
        broadcastManager?.targetPaneIDs = broadcastManager?.targetPaneIDs.filter { validIDs.contains($0) } ?? []
    }

    /// Toggle broadcast mode.
    func toggleBroadcast() {
        broadcastManager?.toggle()
        syncBroadcastTargets()
    }

    // MARK: - Private

    private func resolveConnectionConfig(for tab: TerminalTab, session: TerminalSession) -> SSHConnectionConfig? {
        let hostItem = tab.hostItem
        guard let modelContext else {
            session.connectionState = .disconnected
            session.errorMessage = I18n.shared.t(.noModelContext)
            return nil
        }
        guard let authMethod = hostItem.resolveAuthMethod(modelContext: modelContext) else {
            session.connectionState = .disconnected
            session.errorMessage = I18n.shared.t(.credentialsNotSet)
            return nil
        }
        return SSHConnectionConfig(
            host: hostItem.host,
            port: UInt16(hostItem.port),
            username: hostItem.resolveUsername(modelContext: modelContext),
            authMethod: authMethod,
            maxReconnectAttempts: 0,
            baseReconnectDelay: .seconds(1)
        )
    }

    private func setupPTYSession(for tab: TerminalTab, pane: PaneState, session: TerminalSession, service: SSHNetworkService) async throws {
        Log.session.info("[PTY] Opening PTY session...")
        let ptySession = try await service.openPTY()
        Log.session.info("[PTY] PTY session opened successfully")

        guard tabs.contains(where: { $0.id == tab.id }) else {
            Log.session.warning("[PTY] Tab was closed during PTY setup, aborting")
            return
        }

        pane.ptySession = ptySession
        session.ptySession = ptySession // Keep for backward compatibility
        Log.session.info("[PTY] PTY session assigned to pane")

        ptySession.osc7Detector.onCWDChange = { [weak tab] cwd in
            Task { @MainActor in
                tab?.currentDirectory = cwd
            }
        }

        tab.hostItem.lastConnectedAt = Date()

        session.serverInfoTask?.cancel()
        session.serverInfoTask = Task { [weak session] in
            if let info = await ServerInfoFetcher.fetch(using: service) {
                await MainActor.run { session?.serverInfo = info }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                if let info = await ServerInfoFetcher.fetch(using: service) {
                    await MainActor.run { session?.serverInfo = info }
                }
            }
        }
    }

    private func parseCWD(from title: String) -> String? {
        // Pattern: "user@host:/absolute/path" or "user@host:~/path"
        if let colonRange = title.range(of: ": ") {
            let afterColon = String(title[colonRange.upperBound...])
            let path = afterColon.components(separatedBy: " ").first ?? afterColon
            if path.hasPrefix("/") { return path }
            // Handle ~ paths (assume home directory)
            if path.hasPrefix("~") {
                let home = "/root" // Default for most SSH connections
                let relativePath = path.dropFirst()
                if relativePath.isEmpty { return home }
                if relativePath.hasPrefix("/") {
                    return home + String(relativePath)
                }
                return home + "/" + String(relativePath)
            }
        }
        // Pattern: "/absolute/path" as title
        if title.hasPrefix("/") {
            return title.components(separatedBy: " ").first ?? title
        }
        return nil
    }

    private func observeStateChanges(for tab: TerminalTab, session: TerminalSession, service: SSHNetworkService) {
        session.stateObservationTask = Task { [weak self, weak tab, weak session] in
            guard let self, let tab, let session else { return }
            for await state in service.stateStream {
                guard !Task.isCancelled else { break }
                guard tab.session === session else { break }
                session.connectionState = state

                switch state {
                case .connected:
                    if let newPTY = await service.consumePendingPTY() {
                        // Update the first pane's PTY session
                        if let firstPane = tab.layout.root.paneState {
                            firstPane.ptySession?.close()
                            firstPane.ptySession = newPTY
                            session.ptySession = newPTY
                        }
                        session.connectedAt = Date()
                        session.errorMessage = nil
                    }
                case .disconnected:
                    session.connectedAt = nil
                default:
                    break
                }
            }
        }
    }
}
