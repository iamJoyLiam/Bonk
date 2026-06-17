import os.log
import SwiftData
import SwiftUI

/// Manages multiple concurrent SSH terminal sessions.
@Observable
@MainActor
final class SessionManager {
    private(set) var tabs: [TerminalTab] = []
    var activeTabID: UUID?
    var lastError: String?
    var showError = false
    private let hostKeyStore = PersistentHostKeyStore()
    private let viewCache: TerminalViewCache
    var broadcastManager: BroadcastManager?
    private var modelContext: ModelContext?

    /// Handles input processing, command history, and broadcast.
    let inputHandler = InputHandler()

    /// Handles session persistence (save/restore).
    let sessionPersistence = SessionPersistence()

    /// Centralized session store for lifecycle management.
    let sessionStore = SessionStore.shared

    init(viewCache: TerminalViewCache = .shared) {
        self.viewCache = viewCache
    }

    func setModelContext(_ context: ModelContext) {
        modelContext = context
        sessionPersistence.setModelContext(context)
    }

    var activeTab: TerminalTab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    // MARK: - Tab Management

    func openTab(for host: HostItem) {
        let tab = TerminalTab(hostItem: host)
        tabs.append(tab)
        activeTabID = tab.id
        syncBroadcastTargets()

        // Get or create session from SessionStore
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
        viewCache.remove(id)
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

        // Check if already connecting via SessionStore
        guard !sessionStore.isConnecting(tab.id) else {
            Log.session.warning("[CONNECT] Already connecting to \(tab.hostItem.host), skipping")
            return
        }
        sessionStore.markConnecting(tab.id)
        defer { sessionStore.markConnected(tab.id) }

        // Get or create session from SessionStore
        let session = sessionStore.session(for: tab)
        tab.session = session
        session.connectionState = .connecting
        session.errorMessage = nil
        Log.session.info("[CONNECT] State set to .connecting")

        guard let config = resolveConnectionConfig(for: tab, session: session) else {
            Log.session.error("[CONNECT] Failed to resolve connection config")
            return
        }
        Log.session.info("[CONNECT] Config resolved, creating SSHNetworkService")

        let service = SSHNetworkService(hostKeyStore: hostKeyStore)
        session.sshService = service
        Log.session.info("[CONNECT] SSHNetworkService created, starting state observation")
        observeStateChanges(for: tab, session: session, service: service)

        do {
            Log.session.info("[CONNECT] Calling service.connect()...")
            try await service.connect(config: config)
            Log.session.info("[CONNECT] service.connect() returned successfully")

            guard tabs.contains(where: { $0.id == tab.id }) else {
                Log.session.warning("[CONNECT] Tab was closed during connection, aborting")
                return
            }

            Log.session.info("[CONNECT] Enabling reconnection...")
            await service.enableReconnection(attempts: 3)

            guard tabs.contains(where: { $0.id == tab.id }) else {
                Log.session.warning("[CONNECT] Tab was closed after reconnection setup, aborting")
                return
            }

            session.connectionState = .connected
            session.connectedAt = Date()
            Log.session.info("[CONNECT] State set to .connected, opening PTY...")

            // Publish connected event
            EventPublisher.shared.publish(SessionEvent.connected(tabID: tab.id))

            try await setupPTYSession(for: tab, session: session, service: service)
            Log.session.info("[CONNECT] PTY session established successfully")
        } catch {
            Log.session.error("[CONNECT] Connection failed: \(error.localizedDescription)")
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            session.connectionState = .disconnected
            session.errorMessage = error.localizedDescription
            lastError = error.localizedDescription
            showError = true

            // Publish error event
            EventPublisher.shared.publish(SessionEvent.error(tabID: tab.id, error: error))
        }
    }

    func disconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await sessionStore.disconnect(id)
        tab.session?.disconnect()
        tab.session = nil

        // Publish disconnected event
        EventPublisher.shared.publish(SessionEvent.disconnected(tabID: id))
    }

    func reconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await disconnectTab(id)
        await connectTab(tab)
    }

    // MARK: - Input

    func resizePTY(cols: Int, rows: Int, tabID: UUID) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let service = tab.session?.sshService else { return }
        try await service.resizePTY(cols: cols, rows: rows)
    }

    func updateTabTitle(_ title: String, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if let cwd = parseCWD(from: title) {
            tab.currentDirectory = cwd
        }
    }

    func sendInput(_ bytes: ArraySlice<UInt8>, to tabID: UUID) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        try await inputHandler.sendInput(
            bytes,
            to: tab,
            broadcastManager: broadcastManager,
            allTabs: tabs
        )
    }

    /// Convenience: send text to the active tab (auto-appends Enter).
    func sendTextToActiveTab(_ text: String) {
        guard let tab = activeTab else { return }
        Task { try? await inputHandler.sendText(text, to: tab, broadcastManager: broadcastManager, allTabs: tabs) }
    }

    // MARK: - Broadcast Sync

    private func syncBroadcastTargets() {
        broadcastManager?.allPaneIDs = tabs.map { $0.id }
        let validIDs = Set(tabs.map { $0.id })
        broadcastManager?.targetPaneIDs = broadcastManager?.targetPaneIDs.filter { validIDs.contains($0) } ?? []
    }

    // MARK: - Session Persistence

    func saveSession(for hostItem: HostItem) {
        sessionPersistence.saveSession(for: hostItem)
    }

    func restoreSessions() {
        let hosts = sessionPersistence.restoreHosts()
        for host in hosts {
            let tab = TerminalTab(hostItem: host)
            tabs.append(tab)

            // Create session with restored state (no SSH connection)
            let session = sessionStore.session(for: tab)
            session.connectionState = .restored
            tab.session = session
        }
        if !tabs.isEmpty {
            activeTabID = tabs.first?.id
        }
    }

    func connectFromSession(_ saved: SavedSession) {
        if let host = sessionPersistence.findHost(for: saved) {
            openTab(for: host)
        } else {
            lastError = "Host not found: \(saved.host)"
            showError = true
        }
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

    private func setupPTYSession(for tab: TerminalTab, session: TerminalSession, service: SSHNetworkService) async throws {
        Log.session.info("[PTY] Opening PTY session...")
        let ptySession = try await service.openPTY()
        Log.session.info("[PTY] PTY session opened successfully")

        guard tabs.contains(where: { $0.id == tab.id }) else {
            Log.session.warning("[PTY] Tab was closed during PTY setup, aborting")
            return
        }

        session.ptySession = ptySession
        Log.session.info("[PTY] PTY session assigned (output stream will be created by TerminalContainerView)")

        ptySession.osc7Detector.onCWDChange = { [weak tab] cwd in
            Task { @MainActor in
                tab?.currentDirectory = cwd
            }
        }
        Log.session.info("[PTY] OSC 7 detector wired")

        tab.hostItem.lastConnectedAt = Date()
        Log.session.info("[PTY] PTY setup complete")

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
        if let colonRange = title.range(of: ": ") {
            let afterColon = String(title[colonRange.upperBound...])
            let path = afterColon.components(separatedBy: " ").first ?? afterColon
            if path.hasPrefix("/") { return path }
        }
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
                        session.ptySession?.close()
                        session.ptySession = newPTY
                        let streamResult = newPTY.makeOutputStream()
                        session.outputStream = streamResult.stream
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
