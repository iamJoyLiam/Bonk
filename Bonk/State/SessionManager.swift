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

    /// Guard against the auth-failure dialog loop. One tab goes through at most:
    /// dialog → reconnect → (fail) → cleanup+reconnect → (fail) → STOP. The
    /// user must start a fresh connect to try again.
    private enum AuthRetryState { case idle, dialogShown, cleanupDone }
    private var authRetryState: AuthRetryState = .idle
    private var authRetryTabID: UUID?
    private var isShowingAuthDialog = false
    private var connectTasks: [UUID: Task<Void, Never>] = [:]

    // VNext — Hybrid SSH coordinator (T1.4+). Used for routing decision logging in T2.1,
    // full native-first wiring lands in T2.2.
    let vnextCoordinator = SSHSessionCoordinator()

    var vnextProfileStore: SSHProfileStore? {
        guard let ctx = modelContext else { return nil }
        return SSHProfileStore(context: ctx)
    }

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
        if let paneID = tab.activePaneID {
            TeamRelay.shared.setSharedSession(tabID: tab.id, paneID: paneID)
        }
        syncBroadcastTargets()

        let session = sessionStore.session(for: tab)
        tab.session = session

        let task = Task { await connectTab(tab) }
        connectTasks[tab.id] = task
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
        if let paneID = tab.activePaneID {
            TeamRelay.shared.setSharedSession(tabID: tab.id, paneID: paneID)
        }
        tab.session = sessionStore.session(for: tab)
        syncBroadcastTargets()

        let task = Task { await connectSerialTab(tab, promptSave: true) }
        connectTasks[tab.id] = task
    }

    func selectTab(_ id: UUID) {
        activeTabID = id
        if let tab = tabs.first(where: { $0.id == id }),
           let paneID = tab.activePaneID
        {
            TeamRelay.shared.setSharedSession(tabID: tab.id, paneID: paneID)
        }
    }

    /// Move a tab relative to another tab — Ghostty-style insert.
    /// Dragging left→right inserts *after* target, right→left inserts *before*.
    func moveTab(_ tabID: UUID, relativeTo targetID: UUID) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex
        else { return }

        let tab = tabs.remove(at: sourceIndex)
        guard let newTargetIndex = tabs.firstIndex(where: { $0.id == targetID }) else {
            tabs.append(tab)
            return
        }
        let insertIndex = sourceIndex < targetIndex ? newTargetIndex + 1 : newTargetIndex
        tabs.insert(tab, at: insertIndex)
    }

    func closeTab(_ id: UUID) async {
        connectTasks[id]?.cancel()
        connectTasks[id] = nil
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
            if let tab = activeTab,
               let paneID = tab.activePaneID
            {
                TeamRelay.shared.setSharedSession(tabID: tab.id, paneID: paneID)
            } else {
                TeamRelay.shared.clearSharedSession()
            }
        }
        syncBroadcastTargets()
    }

    /// Disconnect every tab WITHOUT removing it: the tab structure (and its
    /// host) stays, but all ssh children are terminated and PTYs released.
    /// Called when the main window closes — the app keeps running for the
    /// Quake terminal, but no SSH connection may linger in the background.
    func disconnectAllTabs() async {
        for tab in tabs {
            await disconnectTab(tab.id)
        }
    }

    // MARK: - Connection

    func connectTab(_ tab: TerminalTab) async {
        // A fresh manual connect resets the auth-retry state machine.
        authRetryState = .idle
        authRetryTabID = nil
        await connectTab(tab, passwordOverride: nil, resetAuthRetry: false)
    }

    /// Connect a tab. `passwordOverride` supplies a freshly typed password
    /// (from the auth-failure dialog) that replaces the stored credential
    /// for this attempt; on success it is persisted back (vault credential
    /// or host-embedded Keychain entry) so the next connect works silently.
    func connectTab(
        _ tab: TerminalTab,
        passwordOverride: String?,
        resetAuthRetry: Bool = true
    ) async {
        Log.session.info("[CONNECT] Starting connectTab for \(tab.hostItem.host):\(tab.hostItem.port)")

        guard !sessionStore.isConnecting(tab.id) else {
            Log.session.warning("[CONNECT] Already connecting to \(tab.hostItem.host), skipping")
            return
        }
        sessionStore.markConnecting(tab.id)
        defer { sessionStore.markConnected(tab.id) }
        defer { connectTasks[tab.id] = nil }

        let session = sessionStore.session(for: tab)
        tab.session = session
        session.connectionState = .connecting
        session.phase = .resolving
        session.errorMessage = nil

        guard let config = preparedConfig(for: tab, session: session, passwordOverride: passwordOverride) else {
            setPhase(session, to: .failed("resolve config"), host: tab.hostItem.host, engine: "Resolver", reason: "config")
            return
        }
        setPhase(session, to: .connectingTransport, host: config.host, engine: "Resolver", reason: "VNext routing")

        let routing = await vnextRouting(for: config, host: tab.hostItem)
        let vnextReq = routing.requirements
        let vnextCached = routing.cached
        let vnextDecision = routing.decision
        logVNextDecision(vnextDecision, config: config, requirements: vnextReq)

        var service = await makeVNextService(for: vnextDecision)
        var effectiveConfig = effectiveConfig(for: config, decision: vnextDecision, cached: vnextCached)
        if case .compatibility = vnextDecision, let algos = vnextCached?.algorithms, !algos.isEmpty {
            Log.session.info("[VNext] Using cached compat algorithms: kex=\(algos.kex)")
        }
        session.sshService = service
        observeStateChanges(for: tab, session: session, service: service)
        await attachManualPasswordHandler(to: service, tab: tab)

        var fallbackInfo: FallbackInfo?
        let transportEngine: String = {
            switch vnextDecision {
            case .native: return "Native"
            case .compatibility: return "Compatibility"
            case .nativeWithCompatibilityFallback: return "Native"
            }
        }()
        setPhase(session, to: .negotiatingSSH, host: config.host, engine: transportEngine, reason: "transport connect")
        do {
            do {
                try await service.connect(config: effectiveConfig)
            } catch {
                let result = try await handleNativeFallback(
                    error: error, decision: vnextDecision, config: config,
                    requirements: vnextReq, currentService: service,
                    session: session, tab: tab
                )
                service = result.service
                effectiveConfig = result.compatConfig
                fallbackInfo = FallbackInfo(
                    didFallback: true,
                    algorithms: result.algorithms,
                    reason: result.reason
                )
            }

            let finalizeCtx = FinalizeContext(
                config: config, effectiveConfig: effectiveConfig,
                vnextReq: vnextReq, vnextDecision: vnextDecision,
                fallback: fallbackInfo, passwordOverride: passwordOverride
            )
            try await finalizeConnection(tab: tab, session: session, service: service, context: finalizeCtx)
            // Auto-record if enabled
            if let ctx = modelContext, let prefs = try? ctx.fetch(FetchDescriptor<UserPreferences>()).first, prefs.autoRecord == true {
                let pid = tab.activePaneID ?? tab.layout.activePaneID
                Task {
                    if !(await SessionRecordingService.shared.isRecording(paneID: pid)) {
                        _ = try? await SessionRecordingService.shared.start(host: tab.hostItem.name, tabID: tab.id, paneID: pid)
                        tab.layout.findPane(id: pid)?.ptySession?.recordingPaneID = pid
                    }
                }
            }
            Log.session.info("[CONNECT] PTY session established successfully")
        } catch {
            Log.session.error("[CONNECT] Connection failed: \(error.localizedDescription)")
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            setPhase(session, to: .failed(error.localizedDescription), host: config.host, engine: "Session", reason: "failed")
            session.errorMessage = error.localizedDescription
            lastError = error.localizedDescription
            showError = true
        }
    }

    func setPhase(_ session: TerminalSession, to newPhase: SSHConnectionPhase, host: String, engine: String, reason: String) {
        let old = String(describing: session.phase)
        session.phase = newPhase
        // Keep legacy connectionState in sync for non-phase-aware UI
        switch newPhase {
        case .idle, .failed: session.connectionState = .disconnected
        case .ready: session.connectionState = .connected
        case .reconnecting(let attempt, let maxAttempts): session.connectionState = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
        default: session.connectionState = .connecting
        }
        Log.session.info("[SSH_STATE] host:\(host) engine:\(engine) old:\(old) new:\(String(describing: newPhase)) reason:\(reason)")
    }

    /// Save a password to the credential source this host actually uses:
    /// the referenced vault credential, or the host-embedded Keychain entry.
    func persistPassword(_ password: String, for tab: TerminalTab) {
        guard !password.isEmpty else { return }
        if let credential = tab.hostItem.credentialRef {
            credential.storeSecret(password)
            Log.session.info("[CRED] Updated vault credential password for \(tab.hostItem.name, privacy: .public)")
        } else {
            tab.hostItem.updateSavedPassword(password)
            Log.session.info("[CRED] Updated host-embedded password for \(tab.hostItem.name, privacy: .public)")
        }
    }

    /// VNext T3.1 — infer legacy algorithms needed for Compatibility fallback.
    /// Checks error message for known algorithm names; falls back to a minimal
    /// legacy bundle for generic negotiation failures.
    static func inferAlgorithmRequirements(from error: Error) -> SSHAlgorithmRequirements? {
        let msg = (error.localizedDescription + " " + String(describing: error)).lowercased()
        // If not a negotiation failure, no algorithm hint
        guard msg.contains("keyexchangenegotiationfailure") || msg.contains("no matching")
            || msg.contains("invalidhostkeyforkeyexchange") || msg.contains("unsupportedversion") else {
            return nil
        }
        var kex: [String] = []
        var hostKey: [String] = []
        var cipher: [String] = []
        let mac: [String] = []
        // Specific hints in message
        if msg.contains("diffie-hellman-group1-sha1") { kex.append("diffie-hellman-group1-sha1") }
        if msg.contains("diffie-hellman-group14-sha1") { kex.append("diffie-hellman-group14-sha1") }
        if msg.contains("group-exchange") { kex.append("diffie-hellman-group-exchange-sha1") }
        if msg.contains("ssh-rsa") { hostKey.append("ssh-rsa") }
        if msg.contains("ssh-dss") { hostKey.append("ssh-dss") }
        if msg.contains("aes128-cbc") { cipher.append("aes128-cbc") }
        if msg.contains("3des") { cipher.append("3des-cbc") }
        // Generic fallback for legacy bastion (covers H3C / old OpenSSH)
        if kex.isEmpty && hostKey.isEmpty && cipher.isEmpty {
            // Minimal legacy bundle — only added for this host via Compatibility path
            return SSHAlgorithmRequirements(
                kex: ["diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1"],
                hostKey: ["ssh-rsa"],
                cipher: [],
                mac: []
            )
        }
        let req = SSHAlgorithmRequirements(kex: kex, hostKey: hostKey, cipher: cipher, mac: mac)
        return req.isEmpty ? nil : req
    }

    /// Remove stale ControlMaster sockets for a host so a reconnection starts
    /// clean. The sockets are named /tmp/bonk-ssh-{user}-{host}-{port}-*.sock;
    /// deleting one whose master has exited is harmless (OpenSSH recreates it).
    static func cleanupHostControlSockets(username: String, host: String, port: UInt16) {
        let safeUser = username.replacingOccurrences(of: "/", with: "_")
        let safeHost = host.replacingOccurrences(of: "/", with: "_")
        let pattern = "/tmp/bonk-ssh-\(safeUser)-\(safeHost)-\(port)-*.sock"
        var globResult = glob_t()
        let flags = GLOB_NOSORT | GLOB_ERR
        if glob(pattern, flags, nil, &globResult) == 0 {
            for index in 0 ..< globResult.gl_pathc {
                if let pathPointer = globResult.gl_pathv[Int(index)] {
                    let path = String(cString: pathPointer)
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            globfree(&globResult)
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

    func resolveConnectionConfig(for tab: TerminalTab, session: TerminalSession) -> SSHConnectionConfig? {
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

    /// Whether an SSH error message means the saved credential was rejected
    /// (as opposed to a network/host-key problem). Only credential failures
    /// trigger the re-password dialog.
    private static func isAuthFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("permission denied")
            || lower.contains("authentication failed")
            || lower.contains("authentication failure")
            || lower.contains("no supported authentication methods")
    }

    /// Show a modal dialog asking for the password of `username@host`
    /// (username preserved, only the password is entered). Returns nil when
    /// the user cancels.
    private func promptForPassword(username: String, host: String) async -> String? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = I18n.shared.t(.authFailedTitle)
        let displayUser = username.isEmpty ? "?" : username
        alert.informativeText = "\(displayUser)@\(host)\n\(I18n.shared.t(.authFailedMessage))"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = I18n.shared.t(.password)
        container.addSubview(field)
        alert.accessoryView = container

        alert.addButton(withTitle: I18n.shared.t(.retry))
        alert.addButton(withTitle: I18n.shared.t(.cancel))
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    func setupPTYSession(
        for tab: TerminalTab,
        pane: PaneState,
        session: TerminalSession,
        service: SSHNetworkService
    ) async throws {
        Log.session.info("[PTY] Opening PTY session...")
        let ptySession = try await service.openPTY(
            onError: { [weak self, weak tab] message in
                Task { @MainActor in
                    guard let self, let tab else { return }
                    session.errorMessage = message
                    Log.session.error("[AUTH] onError: \(message.prefix(120))")
                    // Authentication was rejected (wrong saved password).
                    guard Self.isAuthFailure(message) else {
                        Log.session.error("[AUTH] not an auth failure, no dialog")
                        return
                    }
                    guard !self.isShowingAuthDialog else {
                        Log.session.warning("[AUTH] dialog already showing, ignoring duplicate failure")
                        return
                    }
                    self.isShowingAuthDialog = true
                    defer { self.isShowingAuthDialog = false }
                    // State machine: at most dialog -> reconnect -> (fail) ->
                    // cleanup+reconnect -> (fail) -> STOP.
                    if self.authRetryState == .dialogShown, self.authRetryTabID == tab.id {
                        Log.session.error("[AUTH] reconnect failed; cleaning stale SSH state and retrying once")
                        OpenSSHBackend.cleanupOrphanedMuxes()
                        self.authRetryState = .cleanupDone
                        guard self.tabs.contains(where: { $0.id == tab.id }) else { return }
                        await self.connectTab(tab, passwordOverride: nil, resetAuthRetry: false)
                        return
                    }
                    if self.authRetryState == .cleanupDone, self.authRetryTabID == tab.id {
                        Log.session.error("[AUTH] giving up: reconnect failed after cleanup. Manual reconnect required.")
                        self.authRetryState = .idle
                        self.authRetryTabID = nil
                        return
                    }
                    self.authRetryState = .dialogShown
                    self.authRetryTabID = tab.id
                    guard self.tabs.contains(where: { $0.id == tab.id }) else { return }
                    guard let password = await self.promptForPassword(
                        username: tab.hostItem.resolveUsername(),
                        host: tab.hostItem.host
                    ) else {
                        Log.session.error("[AUTH] dialog cancelled/empty")
                        self.authRetryState = .idle
                        self.authRetryTabID = nil
                        return
                    }
                    Log.session.info("[AUTH] dialog returned password len=\(password.count) fp=\(OpenSSHBackend.passwordFingerprint(password))")
                    // Reconnect with the typed password; on success it is
                    // persisted to the credential source.
                    await self.connectTab(tab, passwordOverride: password, resetAuthRetry: false)
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
        ptySession.teamSessionID = TeamSessionID(tabID: tab.id, paneID: pane.id)
        Log.session.info("[PTY] PTY session assigned to pane")

        // Notify terminal views to connect output stream
        NotificationCenter.default.post(name: .terminalPTYSessionReady, object: nil, userInfo: ["tabID": tab.id])

        // Post-PTY-setup: sync real terminal dimensions to override the 80x24 default
        // This is done after SSH channel is established to ensure resize doesn't get dropped
        Task { @MainActor [weak self, weak tab, weak pane] in
            // Wait for one RunLoop cycle to ensure SwiftTerm has calculated real dimensions
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, let tab, self.tabs.contains(where: { $0.id == tab.id }),
                  let pane, pane.ptySession === ptySession,
                  let paneID = tab.activePaneID,
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
        Task { @MainActor [weak self, weak ptySession] in
            // Wait for one RunLoop cycle to ensure SwiftTerm has calculated real dimensions
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, let ptySession else { return }
            // Ensure pane still exists and is still bound to this PTY session
            let stillValid = self.tabs.contains { tab in
                tab.layout.findPane(id: paneID)?.ptySession === ptySession
            }
            guard stillValid else { return }
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

    func observeStateChanges(for tab: TerminalTab, session: TerminalSession, service: SSHNetworkService) {
        session.stateObservationTask?.cancel()
        let token = UUID()
        session.stateObserverToken = token
        session.stateObservationTask = Task { [weak self, weak tab, weak session] in
            guard let self, let tab, let session else { return }
            for await state in service.stateStream {
                guard !Task.isCancelled else { break }
                guard session.stateObserverToken == token else { return }
                guard tab.session === session else { break }

                switch state {
                case .connected:
                    if let newPTY = await service.consumePendingPTY() {
                        if let firstPane = tab.layout.root.paneState {
                            firstPane.ptySession?.close()
                            firstPane.ptySession = newPTY
                            session.ptySession = newPTY
                            newPTY.teamSessionID = TeamSessionID(tabID: tab.id, paneID: firstPane.id)
                            TerminalViewCache.shared.rebindOutputStream(for: tab.id, to: newPTY)
                            TerminalViewCache.shared.rebindOutputStream(for: firstPane.id, to: newPTY)
                            syncPTYSize(for: firstPane.id, ptySession: newPTY)
                        }
                        attachPTYSessionObservers(newPTY, to: tab)
                        session.connectedAt = Date()
                        session.errorMessage = nil
                        session.terminalState = .ready
                        self.setPhase(session, to: .ready, host: tab.hostItem.host, engine: "Observer", reason: "reconnect PTY")
                        NotificationCenter.default.post(name: .terminalPTYSessionReady, object: nil, userInfo: ["tabID": tab.id])
                    } else if tab.layout.root.paneState?.ptySession != nil {
                        session.terminalState = .ready
                        self.setPhase(session, to: .ready, host: tab.hostItem.host, engine: "Observer", reason: "PTY ready")
                    } else {
                        Log.session.debug("[CONNECT] Ignoring .connected before PTY ready (phase=\(String(describing: session.phase)))")
                    }
                case .disconnected:
                    session.connectedAt = nil
                    if case .failed = session.phase { break }
                    self.setPhase(session, to: .idle, host: tab.hostItem.host, engine: "Observer", reason: "disconnected")
                case .reconnecting(let attempt, let max):
                    self.setPhase(session, to: .reconnecting(attempt: attempt, maxAttempts: max), host: tab.hostItem.host, engine: "Observer", reason: "reconnecting")
                case .connecting:
                    if case .idle = session.phase {
                        self.setPhase(session, to: .connectingTransport, host: tab.hostItem.host, engine: "Observer", reason: "connecting")
                    } else {
                        session.connectionState = state
                    }
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
        defer { connectTasks[tab.id] = nil }

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
                ptySession.teamSessionID = TeamSessionID(tabID: tab.id, paneID: firstPane.id)
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
