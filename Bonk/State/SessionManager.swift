import os.log
import SwiftData
import SwiftUI

/// Manages multiple concurrent SSH terminal sessions.
@Observable
@MainActor
final class SessionManager {
    var tabs: [TerminalTab] = []
    var activeTabID: UUID?
    var lastError: String?
    var showError = false
    private let hostKeyStore = PersistentHostKeyStore()
    private var connectingTabs = Set<UUID>()
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    var activeTab: TerminalTab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    // MARK: - Tab Management

    func openTab(for host: HostItem) {
        let tab = TerminalTab(hostItem: host)
        tabs.append(tab)
        activeTabID = tab.id
        Task { await connectTab(tab) }
    }

    func selectTab(_ id: UUID) {
        activeTabID = id
    }

    func closeTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await disconnectTab(id)
        // Remove cached terminal view to free memory
        TerminalViewCache.shared.remove(id)
        tabs.removeAll(where: { $0.id == id })
        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
    }

    // MARK: - Connection

    func connectTab(_ tab: TerminalTab) async {
        guard !connectingTabs.contains(tab.id) else { return }
        connectingTabs.insert(tab.id)
        defer { connectingTabs.remove(tab.id) }

        tab.connectionState = .connecting
        tab.errorMessage = nil

        guard let config = resolveConnectionConfig(for: tab) else { return }

        let service = SSHNetworkService(hostKeyStore: hostKeyStore)
        tab.sshService = service
        observeStateChanges(for: tab, service: service)

        do {
            Log.session.info(" Connecting to \(tab.hostItem.host):\(tab.hostItem.port)...")
            try await service.connect(config: config)
            guard tabs.contains(where: { $0.id == tab.id }) else { return }

            Log.session.info(" Connected! Enabling reconnection...")
            await service.enableReconnection(attempts: 3)
            guard tabs.contains(where: { $0.id == tab.id }) else { return }

            tab.connectionState = .connected
            tab.connectedAt = Date()
            Log.session.info(" Opening PTY...")

            try await setupPTYSession(for: tab, service: service)
        } catch {
            // Don't show error if tab was closed during connection
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            Log.session.info(" Error: \(error)")
            tab.connectionState = .disconnected
            tab.errorMessage = error.localizedDescription
            lastError = error.localizedDescription
            showError = true
        }
    }

    func disconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.stateObservationTask?.cancel()
        tab.stateObservationTask = nil
        tab.serverInfoTask?.cancel()
        tab.serverInfoTask = nil
        tab.serverInfo = nil
        tab.ptySession?.close()
        tab.ptySession = nil
        await tab.sshService?.disconnect()
        tab.sshService = nil
        tab.connectionState = .disconnected
        tab.connectedAt = nil
    }

    func reconnectTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        await disconnectTab(id)
        await connectTab(tab)
    }

    // MARK: - Input

    func resizePTY(cols: Int, rows: Int, tabID: UUID) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let service = tab.sshService else { return }
        try await service.resizePTY(cols: cols, rows: rows)
    }

    func updateTabTitle(_ title: String, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if let cwd = parseCWD(from: title) {
            tab.currentDirectory = cwd
        }
    }

    func sendInput(_ bytes: ArraySlice<UInt8>, to tabID: UUID) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let pty = tab.ptySession else { return }
        try await pty.sendInput(bytes)
    }

    // MARK: - Private

    /// Validate host credentials and build SSH connection config. Sets error state on tab if validation fails.
    private func resolveConnectionConfig(for tab: TerminalTab) -> SSHConnectionConfig? {
        let hostItem = tab.hostItem
        guard let modelContext else {
            tab.connectionState = .disconnected
            tab.errorMessage = I18n.shared.t(.noModelContext)
            return nil
        }
        guard let authMethod = hostItem.resolveAuthMethod(modelContext: modelContext) else {
            tab.connectionState = .disconnected
            tab.errorMessage = I18n.shared.t(.credentialsNotSet)
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

    /// Open PTY session, wire OSC 7 CWD detector, and start periodic server info fetching.
    private func setupPTYSession(for tab: TerminalTab, service: SSHNetworkService) async throws {
        let ptySession = try await service.openPTY()
        guard tabs.contains(where: { $0.id == tab.id }) else { return }

        tab.ptySession = ptySession
        let streamResult = ptySession.makeOutputStream()
        tab.outputStream = streamResult.stream

        // Wire OSC 7 CWD detector
        ptySession.osc7Detector.onCWDChange = { [weak tab] cwd in
            Task { @MainActor in
                tab?.currentDirectory = cwd
            }
        }
        Log.session.info("PTY opened, OSC 7 detector wired")

        tab.hostItem.lastConnectedAt = Date()

        // Fetch server system info and refresh periodically
        tab.serverInfoTask?.cancel()
        tab.serverInfoTask = Task { [weak tab] in
            if let info = await ServerInfoFetcher.fetch(using: service) {
                await MainActor.run { tab?.serverInfo = info }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                if let info = await ServerInfoFetcher.fetch(using: service) {
                    await MainActor.run { tab?.serverInfo = info }
                }
            }
        }
    }

    /// Parse current working directory from terminal title.
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

    private func observeStateChanges(for tab: TerminalTab, service: SSHNetworkService) {
        tab.stateObservationTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            for await state in service.stateStream {
                guard !Task.isCancelled else { break }
                Log.session.debug("Stream update for tab \(tab.title)")
                tab.connectionState = state

                switch state {
                case .connected:
                    if let newPTY = await service.consumePendingPTY() {
                        tab.ptySession?.close()
                        tab.ptySession = newPTY
                        let streamResult = newPTY.makeOutputStream()
                        tab.outputStream = streamResult.stream
                        tab.connectedAt = Date()
                        tab.errorMessage = nil
                        Log.session.debug(" PTY restored from reconnect")
                    }
                case .disconnected:
                    tab.connectedAt = nil
                    Log.session.debug(" Disconnected, connectedAt nilled")
                default:
                    break
                }
            }
        }
    }
}
