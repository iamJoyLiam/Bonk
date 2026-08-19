import os.log
import SwiftData
import SwiftTerm
import SwiftUI

/// Manages multiple concurrent SSH terminal sessions.
@Observable
@MainActor
final class SessionManager {
    /// All tabs (each tab is a workspace with its own split layout).
    var tabs: [TerminalTab] = []

    var activeTabID: UUID?

    var lastError: String?
    var showError = false
    /// Serial connection that just succeeded and is waiting for the user to
    /// decide whether to save it to the sidebar.
    var pendingSerialSave: SerialPortConfig?
    /// Currently dragging tab ID (memory state for drag-and-drop).
    var draggingTabID: UUID?
    /// Target tab ID when dragging over a tab (for showing indicator).
    var dragTargetTabID: UUID?
    let hostKeyStore = PersistentHostKeyStore()
    let viewCache: TerminalViewCache
    var broadcastManager: BroadcastManager?
    var modelContext: ModelContext?

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

    /// Open a host, dispatching to serial or SSH based on host type.
    func openHost(_ host: HostItem) {
        if host.isSerial == true {
            openSerialTab(config: SerialPortConfig(
                name: host.name,
                path: host.host,
                baudRate: host.serialBaudRate ?? 115_200
            ))
        } else {
            openTab(for: host)
        }
    }

    /// Open a serial port connection in a new terminal tab.
    func openSerialTab(config: SerialPortConfig) {
        let displayName = config.name.isEmpty ? config.path : config.name
        let host = HostItem(
            name: displayName,
            host: config.path,
            port: 0,
            username: "serial"
        )
        let tab = TerminalTab(hostItem: host)
        tab.title = displayName
        tab.serialConfig = config
        tabs.append(tab)
        activeTabID = tab.id
        tab.session = sessionStore.session(for: tab)
        syncBroadcastTargets()

        Task { await connectSerialTab(tab, promptSave: true) }
    }

    func selectTab(_ id: UUID) {
        activeTabID = id
    }

    /// Move a tab relative to another tab (for drop-target reordering).
    /// The dragged tab swaps with the target tab.
    func moveTab(_ tabID: UUID, relativeTo targetID: UUID) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex
        else { return }

        tabs.swapAt(sourceIndex, targetIndex)
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

        // When the stored password was wrong and the user types a working
        // one into the terminal, refresh the saved credential so the next
        // connect succeeds automatically.
        await service.setManualPasswordHandler { [weak tab] password in
            Task { @MainActor in
                tab?.hostItem.updateSavedPassword(password)
                Log.session.info("[CONNECT] Manual password accepted; saved credential updated")
            }
        }

        do {
            try await service.connect(config: config)

            guard tabs.contains(where: { $0.id == tab.id }) else { return }

            await service.enableReconnection(attempts: 3)

            guard tabs.contains(where: { $0.id == tab.id }) else { return }

            // Connect the first pane
            if let firstPane = tab.layout.root.paneState {
                try await setupPTYSession(for: tab, pane: firstPane, session: session, service: service)
            }
            // Only mark connected once the PTY is actually established, so the
            // UI never renders a terminal view without a live PTY session.
            session.connectionState = .connected
            session.connectedAt = Date()
            Log.session.info("[CONNECT] PTY session established successfully")
        } catch {
            Log.session.error("[CONNECT] Connection failed: \(error.localizedDescription)")
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            session.connectionState = .disconnected
            session.errorMessage = error.localizedDescription
            lastError = error.localizedDescription
            showError = true

        }
    }

    func disconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await sessionStore.disconnect(id)
        // Close all pane PTY sessions and clean up cached views
        for paneID in tab.paneIDs {
            tab.layout.findPane(id: paneID)?.ptySession?.close()
            viewCache.remove(paneID)
        }
        tab.session?.disconnect()
        tab.session = nil

    }

    func reconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await disconnectTab(id)
        if tab.serialConfig != nil {
            await connectSerialTab(tab)
        } else {
            await connectTab(tab)
        }
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
        if let cwd = parseCWD(from: title, username: tab.hostItem.username) {
            tab.currentDirectory = cwd
        }
    }

    func sendInput(_ bytes: ArraySlice<UInt8>, to tabID: UUID, paneID: UUID? = nil) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let targetPaneID = paneID ?? tab.activePaneID else { return }

        // Use inputHandler to record command history and broadcast
        try await inputHandler.sendInput(
            bytes,
            to: tab,
            paneID: targetPaneID,
            broadcastManager: broadcastManager,
            allTabs: tabs
        )
    }

    // MARK: - Zmodem

    /// Start Zmodem file send.
    func startZmodemSend(tabID: UUID, paneID: UUID, files: [URL]) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let pane = tab.layout.findPane(id: paneID),
              let pty = pane.ptySession else { return }

        if pty.zmodemHandler == nil {
            pty.setupZmodem()
        }
        pty.startZmodemSend(files: files)
    }

    /// Start Zmodem file receive.
    func startZmodemReceive(tabID: UUID, paneID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let pane = tab.layout.findPane(id: paneID),
              let pty = pane.ptySession else { return }

        if pty.zmodemHandler == nil {
            pty.setupZmodem()
        }
        pty.startZmodemReceive()
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

    // MARK: - Broadcast Sync

    func syncBroadcastTargets() {
        let allPaneIDs = tabs.flatMap(\.paneIDs)
        broadcastManager?.allPaneIDs = allPaneIDs
        let validIDs = Set(allPaneIDs)
        broadcastManager?.targetPaneIDs = broadcastManager?.targetPaneIDs.filter { validIDs.contains($0) } ?? []
    }

    // MARK: - Private

    private func resolveConnectionConfig(for tab: TerminalTab, session: TerminalSession) -> SSHConnectionConfig? {
        let hostItem = tab.hostItem
        guard modelContext != nil else {
            session.connectionState = .disconnected
            session.errorMessage = I18n.shared.t(.noModelContext)
            return nil
        }
        switch SSHConnectionConfigBuilder.makeConfig(for: hostItem) {
        case .success(let config):
            return config
        case .failure(let message):
            session.connectionState = .disconnected
            session.errorMessage = message.localizedDescription
            return nil
        }
    }

    private func setupPTYSession(
        for tab: TerminalTab,
        pane: PaneState,
        session: TerminalSession,
        service: SSHNetworkService
    ) async throws {
        Log.session.info("[PTY] Opening PTY session...")
        let ptySession = try await service.openPTY(
            onError: { [weak session] message in
                Task { @MainActor in
                    session?.errorMessage = message
                }
            }
        )
        Log.session.info("[PTY] PTY session opened successfully")

        guard tabs.contains(where: { $0.id == tab.id }) else {
            Log.session.warning("[PTY] Tab was closed during PTY setup, aborting")
            throw SSHServiceError.connectionFailed("Tab was closed during PTY setup")
        }

        pane.ptySession = ptySession
        session.ptySession = ptySession // Keep for backward compatibility
        Log.session.info("[PTY] PTY session assigned to pane")

        // Notify terminal views to connect output stream
        NotificationCenter.default.post(name: .terminalPTYSessionReady, object: nil, userInfo: ["tabID": tab.id])

        // Post-PTY-setup: sync real terminal dimensions to override the 80x24 default
        // This is done after SSH channel is established to ensure resize doesn't get dropped
        Task { @MainActor [weak tab] in
            // Wait for one RunLoop cycle to ensure SwiftTerm has calculated real dimensions
            try? await Task.sleep(for: .milliseconds(100))
            guard let tab, let paneID = tab.activePaneID,
                  let cached = TerminalViewCache.shared.retrieve(paneID) else { return }
            let cols = cached.view.terminal.cols
            let rows = cached.view.terminal.rows
            guard cols > 0, rows > 0 else { return }
            Log.session.info("[PTY] Post-setup sync: \(cols)x\(rows)")
            try? await ptySession.resize(cols: cols, rows: rows)
        }

        ptySession.osc7Detector.onCWDChange = { [weak tab] cwd in
            Task { @MainActor in
                tab?.currentDirectory = cwd
            }
        }

        tab.hostItem.lastConnectedAt = Date()
    }

    /// Attach per-session observers to a PTY session (used after reconnect).
    private func attachPTYSessionObservers(_ ptySession: PTYSession, to tab: TerminalTab) {
        ptySession.osc7Detector.onCWDChange = { [weak tab] cwd in
            Task { @MainActor in
                tab?.currentDirectory = cwd
            }
        }
    }

    /// Sync the real terminal dimensions to the PTY session after the view has
    /// laid out, overriding the 80x24 default.
    private func syncPTYSize(for paneID: UUID?, ptySession: PTYSession) {
        guard let paneID else { return }
        Task { @MainActor [weak ptySession] in
            // Wait for one RunLoop cycle to ensure SwiftTerm has calculated real dimensions
            try? await Task.sleep(for: .milliseconds(100))
            guard let ptySession else { return }
            guard let cached = TerminalViewCache.shared.retrieve(paneID) else { return }
            let cols = cached.view.terminal.cols
            let rows = cached.view.terminal.rows
            guard cols > 0, rows > 0 else { return }
            Log.session.info("[PTY] Post-setup sync: \(cols)x\(rows)")
            try? await ptySession.resize(cols: cols, rows: rows)
        }
    }

    private func parseCWD(from title: String, username: String) -> String? {
        // Pattern: "user@host:/absolute/path" or "user@host:~/path"
        if let colonRange = title.range(of: ": ") {
            let afterColon = String(title[colonRange.upperBound...])
            let path = afterColon.components(separatedBy: " ").first ?? afterColon
            if path.hasPrefix("/") { return path }
            // Handle ~ paths — expand to the actual user's home directory
            if path.hasPrefix("~") {
                let home = "/home/\(username)"
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

                switch state {
                case .connected:
                    if let newPTY = await service.consumePendingPTY() {
                        // Update the first pane's PTY session
                        if let firstPane = tab.layout.root.paneState {
                            firstPane.ptySession?.close()
                            firstPane.ptySession = newPTY
                            session.ptySession = newPTY
                            // Rebind the terminal to the fresh session and reset
                            // it — the old output stream is already dead, which
                            // otherwise leaves a frozen, unresponsive terminal.
                            // Single-pane views cache by tab.id, split panes by
                            // pane.id — cover both.
                            TerminalViewCache.shared.rebindOutputStream(for: tab.id, to: newPTY)
                            TerminalViewCache.shared.rebindOutputStream(for: firstPane.id, to: newPTY)
                            syncPTYSize(for: firstPane.id, ptySession: newPTY)
                        }
                        attachPTYSessionObservers(newPTY, to: tab)
                        session.connectedAt = Date()
                        session.errorMessage = nil
                        session.connectionState = .connected
                        NotificationCenter.default.post(
                            name: .terminalPTYSessionReady,
                            object: nil,
                            userInfo: ["tabID": tab.id]
                        )
                    } else if tab.layout.root.paneState?.ptySession != nil {
                        // Initial connect: PTY already attached by connectTab.
                        session.connectionState = .connected
                    } else {
                        // Stale/early connected signal — no PTY yet. Holding the
                        // current state avoids a blank terminal with no session.
                        Log.session.debug("[CONNECT] Ignoring .connected before PTY ready")
                    }
                case .disconnected:
                    session.connectedAt = nil
                    session.connectionState = .disconnected
                default:
                    session.connectionState = state
                    break
                }
            }
        }
    }

    // MARK: - Serial Connection

    private func connectSerialTab(_ tab: TerminalTab, promptSave: Bool = false) async {
        guard let config = tab.serialConfig else { return }
        guard !sessionStore.isConnecting(tab.id) else { return }
        sessionStore.markConnecting(tab.id)
        defer { sessionStore.markConnected(tab.id) }

        let session = sessionStore.session(for: tab)
        tab.session = session
        session.connectionState = .connecting
        session.errorMessage = nil

        do {
            let ptySession = try SerialPortService.shared.openSession(
                config: config,
                onDisconnect: { [weak session] in
                    Task { @MainActor in
                        guard let session else { return }
                        session.connectionState = .disconnected
                        session.errorMessage = "Serial port disconnected"
                    }
                }
            )

            guard tabs.contains(where: { $0.id == tab.id }) else {
                ptySession.close()
                return
            }

            if let firstPane = tab.layout.root.paneState {
                firstPane.ptySession = ptySession
            }
            session.ptySession = ptySession
            session.connectionState = .connected
            session.connectedAt = Date()
            NotificationCenter.default.post(
                name: .terminalPTYSessionReady,
                object: nil,
                userInfo: ["tabID": tab.id]
            )
            Log.session.info("[SERIAL] Connected to \(config.path)")
            if promptSave {
                pendingSerialSave = config
            }
        } catch {
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            session.connectionState = .disconnected
            session.errorMessage = error.localizedDescription
            lastError = error.localizedDescription
            showError = true
            Log.session.error("[SERIAL] Connect failed: \(error.localizedDescription)")
        }
    }
}
