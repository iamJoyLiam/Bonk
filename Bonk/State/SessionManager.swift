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
    // Per-tab isolation — fix global singleton causing second tab Sheet suppressed
    private var authRetryStates: [UUID: AuthRetryState] = [:]
    private var showingAuthDialogs: Set<UUID> = []
    private var connectTasks: [UUID: Task<Void, Never>] = [:]
    var transientAuthResults: [UUID: AuthRetryResult] = [:]
    private func retryState(for tabID: UUID) -> AuthRetryState { authRetryStates[tabID] ?? .idle }
    private func setRetryState(_ state: AuthRetryState, for tabID: UUID) {
        if case .idle = state { authRetryStates.removeValue(forKey: tabID) } else { authRetryStates[tabID] = state }
    }
    private func isShowingDialog(for tabID: UUID) -> Bool { showingAuthDialogs.contains(tabID) }
    private func setShowingDialog(_ showing: Bool, for tabID: UUID) {
        if showing { showingAuthDialogs.insert(tabID) } else { showingAuthDialogs.remove(tabID) }
    }

    // MARK: - Auth Retry Sheet (P1 bug 2/3/4)
    struct AuthRetryRequest: Identifiable, @unchecked Sendable {
        let id = UUID()
        let tab: TerminalTab
        let host: HostItem
        let rawError: String
        let lastAttemptPassword: String?
    }
    struct AuthRetryResult: Sendable {
        let password: String
        let privateKeyPEM: String
        let certificatePEM: String
        let secureEnclaveTag: String?
        let credentialID: PersistentIdentifier?
        let authType: AuthType
    }
    var authRetryRequest: AuthRetryRequest?
    var hostToEdit: HostItem?
    private var authRetryContinuation: CheckedContinuation<AuthRetryResult?, Never>?
    /// Last retry password per tab for sheet prefill
    private var lastRetryPassword: [UUID: String] = [:]

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
        authRetryStates.removeValue(forKey: id)
        showingAuthDialogs.remove(id)
        transientAuthResults.removeValue(forKey: id)
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
        // A fresh manual connect resets the auth-retry state machine (per-tab) and clears any stale transient auth
        // to ensure the next connect uses the saved credential (not a previous wrong password) and stays fast (~1s).
        setRetryState(.idle, for: tab.id)
        setShowingDialog(false, for: tab.id)
        transientAuthResults.removeValue(forKey: tab.id)
        lastRetryPassword.removeValue(forKey: tab.id)
        await connectTab(tab, passwordOverride: nil, resetAuthRetry: false)
    }

    /// Connect a tab. `passwordOverride` supplies a freshly typed password
    /// (from the auth-failure dialog) that replaces the stored credential
    /// for this attempt; on success it is persisted back (vault credential
    /// or host-embedded Keychain entry) so the next connect works silently.
    func connectTab(
        _ tab: TerminalTab,
        passwordOverride: String? = nil,
        ephemeralResult: AuthRetryResult? = nil,
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
        
        // New generation for full-chain isolation
        let generation = UUID()
        session.generation = generation
        session.cancelAuthFailureWaiter()
        
        // Disconnect old service to avoid concurrent ssh/askpass
        if let oldService = session.sshService {
            await oldService.disconnect()
        }
        
        session.connectionState = .connecting
        session.phase = .resolving
        session.errorMessage = nil
        session.failureReason = nil

        // Merge transient retry result; keep for cleaning retry, clear on success (300ms)
        let effectiveEphemeral = ephemeralResult ?? transientAuthResults[tab.id]
        if let effectiveResult = effectiveEphemeral { transientAuthResults[tab.id] = effectiveResult }
        guard let config = preparedConfig(for: tab, session: session, passwordOverride: passwordOverride, ephemeralResult: effectiveEphemeral) else {
            setPhase(session, to: .failed("resolve config"), host: tab.hostItem.host, engine: "Resolver", reason: "config")
            return
        }
        // Inject generation for full-chain propagation
        var configWithGen = config
        configWithGen = SSHConnectionConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            jumpHost: config.jumpHost,
            maxReconnectAttempts: config.maxReconnectAttempts,
            baseReconnectDelay: config.baseReconnectDelay,
            algorithmRequirements: config.algorithmRequirements,
            bypassControlMaster: config.bypassControlMaster,
            generation: generation
        )
        setPhase(session, to: .connectingTransport, host: configWithGen.host, engine: "Resolver", reason: "VNext routing")
        // Lifecycle consumes config with ephemeralResult to avoid HostItem overwrite
        let lifecycle = SSHSessionLifecycle(networkService: SSHNetworkService(hostKeyStore: hostKeyStore), hostKeyStore: hostKeyStore)
        guard let resolved = await lifecycle.resolve(config: configWithGen, forcedCompatibility: tab.hostItem.forceCompatibility == true) else {
            setPhase(session, to: .failed("resolve"), host: tab.hostItem.host, engine: "Lifecycle", reason: "resolve")
            return
        }
        let vnextReq = resolved.requirements
        let vnextCached: SSHSessionCoordinator.CachedProfile? = nil
        let vnextDecision = resolved.decision
        logVNextDecision(vnextDecision, config: config, requirements: vnextReq)
        var service = resolved.service
        var effectiveConfig = resolved.effectiveConfig
        // Ensure generation forwarded to effectiveConfig
        if effectiveConfig.generation == nil {
            effectiveConfig = SSHConnectionConfig(
                host: effectiveConfig.host,
                port: effectiveConfig.port,
                username: effectiveConfig.username,
                authMethod: effectiveConfig.authMethod,
                jumpHost: effectiveConfig.jumpHost,
                maxReconnectAttempts: effectiveConfig.maxReconnectAttempts,
                baseReconnectDelay: effectiveConfig.baseReconnectDelay,
                algorithmRequirements: effectiveConfig.algorithmRequirements,
                bypassControlMaster: effectiveConfig.bypassControlMaster,
                generation: generation
            )
        }
        if let effectiveResult = effectiveEphemeral {
            let src = ephemeralResult == nil ? "transient" : "ephemeral"
            let passwordLength = effectiveResult.password.count
            let fingerprint = passwordLength>0 ? OpenSSHBackend.passwordFingerprint(effectiveResult.password) : "-"
            Log.session.info("[AUTH_RETRY] source=\(src, privacy: .public) passwordLength=\(passwordLength) passwordFingerprint=\(fingerprint, privacy: .public) authType=\(effectiveResult.authType.rawValue, privacy: .public) effectiveHost=\(effectiveConfig.host, privacy: .public)")
        }
        if case .compatibility = vnextDecision, let algos = vnextCached?.algorithms, !algos.isEmpty {
            Log.session.info("[VNext] Using cached compat algorithms: kex=\(algos.kex)")
        }
        session.sshService = service
        observeStateChanges(for: tab, session: session, service: service)
        await attachManualPasswordHandler(to: service, tab: tab)
        // Reconnect PTY auth failure must also show sheet
        await service.setAuthFailureHandler { [weak self, weak tab] failure in
            guard let self, let tab else { return }
            Task { @MainActor in
                await self.handleServiceAuthFailure(failure, for: tab)
            }
        }

        var fallbackInfo: FallbackInfo?
        let transportEngine: String = {
            switch vnextDecision {
            case .native: return "Native"
            case .compatibility: return "Compatibility"
            case .nativeWithCompatibilityFallback: return "Native"
            }
        }()
        setPhase(session, to: .negotiatingSSH, host: configWithGen.host, engine: transportEngine, reason: "transport connect")
        do {
            do {
                try await service.connect(config: effectiveConfig)
            } catch {
                let result = try await handleNativeFallback(
                    error: error, decision: vnextDecision, config: configWithGen,
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
                // Register auth handler for fallback service
                await service.setAuthFailureHandler { [weak self, weak tab] failure in
                    guard let self, let tab else { return }
                    Task { @MainActor in await self.handleServiceAuthFailure(failure, for: tab) }
                }
            }

            let finalizeCtx = FinalizeContext(
                config: config, effectiveConfig: effectiveConfig,
                vnextReq: vnextReq, vnextDecision: vnextDecision,
                fallback: fallbackInfo, passwordOverride: passwordOverride, ephemeralResult: effectiveEphemeral
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
            let rawError = error.localizedDescription
            let displayError = SSHErrorMessageParser.explain(rawError, host: config.host, jumpHost: config.jumpHost?.host) ?? rawError
            if Self.isAuthFailure(rawError) || Self.isAuthFailure(displayError) {
                Log.session.info("[SSH_FAILURE] type=authentication backend=citadel msg=\(displayError.prefix(120), privacy: .public)")
                Log.session.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed")
                await service.suppressRecoveryForAuth()
                session.failureReason = .authentication(.permissionDenied(displayError))
                session.errorMessage = displayError
                setPhase(session, to: .failed(displayError), host: configWithGen.host, engine: "Session", reason: "authFailed")
                session.signalAuthFailure()
                guard !isShowingDialog(for: tab.id) else { return }
                setShowingDialog(true, for: tab.id)
                defer { setShowingDialog(false, for: tab.id) }
                if retryState(for: tab.id) == .dialogShown {
                    Log.session.error("[AUTH] Citadel reconnect failed; cleaning and retry once")
                    OpenSSHBackend.cleanupOrphanedMuxes()
                    setRetryState(.cleanupDone, for: tab.id)
                    sessionStore.markConnected(tab.id)
                    let reuse = transientAuthResults[tab.id]
                    if let reuseResult = reuse, reuseResult.authType == .password, !reuseResult.password.isEmpty {
                        await connectTab(tab, passwordOverride: reuseResult.password, ephemeralResult: reuseResult, resetAuthRetry: false)
                    } else {
                        await connectTab(tab, ephemeralResult: reuse, resetAuthRetry: false)
                    }
                    if case .failed = tab.session?.phase {
                    } else { setRetryState(.idle, for: tab.id) }
                    return
                }
                if retryState(for: tab.id) == .cleanupDone {
                    Log.session.error("[AUTH] Citadel second failure; re-show sheet")
                    setRetryState(.idle, for: tab.id)
                }
                setRetryState(.dialogShown, for: tab.id)
                guard let result = await requestAuthRetry(for: tab, rawError: rawError) else {
                    setRetryState(.idle, for: tab.id); lastError = displayError; showError = true; return
                }
                sessionStore.markConnected(tab.id)
                transientAuthResults[tab.id] = result
                if result.authType == .password, !result.password.isEmpty {
                    await connectTab(tab, passwordOverride: result.password, ephemeralResult: result, resetAuthRetry: false)
                } else {
                    await connectTab(tab, ephemeralResult: result, resetAuthRetry: false)
                }
                if case .failed = tab.session?.phase { transientAuthResults[tab.id] = nil } else { setRetryState(.idle, for: tab.id) }
                return
            }
            if let svc = error as? SSHServiceError, case .hostKeyMismatch = svc {
                session.failureReason = .hostKey(displayError)
                Log.session.info("[SSH_FAILURE] type=hostKey backend=citadel msg=\(displayError.prefix(120), privacy: .public)")
                Log.session.info("[RECOVERY_GATE] blocked=true reason=hostKey")
                await service.suppressRecoveryForAuth()
            } else {
                session.failureReason = .transport(.unknown(displayError))
                Log.session.info("[SSH_FAILURE] type=transport backend=citadel msg=\(displayError.prefix(120), privacy: .public)")
                Log.session.info("[RECOVERY_GATE] blocked=false reason=transportFailed")
            }
            setPhase(session, to: .failed(displayError), host: configWithGen.host, engine: "Session", reason: "failed")
            session.errorMessage = displayError
            lastError = displayError
            showError = true
        }
    }

    func setPhase(_ session: TerminalSession, to newPhase: SSHConnectionPhase, host: String, engine: String, reason: String) {
        let old = String(describing: session.phase)
        // Direct assignment for phase to avoid stale read in sendInput/finalize guards
        // connectionState is also @Observable but can be updated synchronously on MainActor
        if Thread.isMainThread {
            session.phase = newPhase
            switch newPhase {
            case .idle, .failed: session.connectionState = .disconnected
            case .ready: session.connectionState = .connected
            case .reconnecting(let attempt, let maxAttempts): session.connectionState = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
            default: session.connectionState = .connecting
            }
            Log.session.info("[SSH_STATE] host:\(host) engine:\(engine) old:\(old) new:\(String(describing: newPhase)) reason:\(reason)")
        } else {
            Task { @MainActor in
                session.phase = newPhase
                switch newPhase {
                case .idle, .failed: session.connectionState = .disconnected
                case .ready: session.connectionState = .connected
                case .reconnecting(let attempt, let maxAttempts): session.connectionState = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
                default: session.connectionState = .connecting
                }
                Log.session.info("[SSH_STATE] host:\(host) engine:\(engine) old:\(old) new:\(String(describing: newPhase)) reason:\(reason)")
            }
        }
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
        if let svc = tab.session?.sshService { await svc.setAuthFailureHandler(nil) }
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
        if let service = tab.session?.sshService {
            // Fix for 202: if service never configured supervisor (host unknown) or is disconnected/failed,
            // requestRecovery will loop with no probe. Do full reconnect instead.
            let state = await service.connectionState
            if case .disconnected = state {
                await disconnectTab(id)
                if tab.serialConfig != nil {
                    await connectSerialTab(tab)
                } else {
                    await connectTab(tab)
                }
                return
            }
            // Check if supervisor has no probe (unknown host) by checking if last failure was transport and state is failed
            if let session = tab.session, case .failed = session.phase {
                await disconnectTab(id)
                await connectTab(tab)
                return
            }
            await service.requestRecovery(reason: .userRequested)
            return
        }
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
        // Only block input during authenticating to avoid command typed as password
        // waitingPTY/openingChannel/openingPTY should allow input (fixes terminal freeze after 2.7)
        if let sessionState = tab.session, sessionState.phase == .authenticating {
            return
        }

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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            let cmdBytes = Array(trimmed.utf8)[...]
            try? await sendInput(cmdBytes, to: tab.id, paneID: paneID)
            try? await Task.sleep(for: .milliseconds(15))
            let enterBytes: ArraySlice<UInt8> = [13]
            try? await sendInput(enterBytes, to: tab.id, paneID: paneID)
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
            || lower.contains("allauthenticationoptionsfailed")
            || lower.contains("all authentication options failed")
            || lower.contains("no authentication methods")
            || lower.contains("auth failed")
            || lower.contains("username or password")
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
        let field = AutoEnglishSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
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

    /// New auth retry via sheet - shows AuthRetrySheet with full auth methods and raw error detail.
    func requestAuthRetry(for tab: TerminalTab, rawError: String) async -> AuthRetryResult? {
        let last = lastRetryPassword[tab.id]
        return await withCheckedContinuation { continuation in
            authRetryContinuation = continuation
            authRetryRequest = AuthRetryRequest(tab: tab, host: tab.hostItem, rawError: rawError, lastAttemptPassword: last)
        }
    }

    func completeAuthRetry(with result: AuthRetryResult?) {
        if let authResult = result, !authResult.password.isEmpty, let tabID = authRetryRequest?.tab.id {
            lastRetryPassword[tabID] = authResult.password
        } else if result == nil, let tabID = authRetryRequest?.tab.id {
            // Keep last input for next prefill
        }
        authRetryContinuation?.resume(returning: result)
        authRetryContinuation = nil
        authRetryRequest = nil
    }

    func completeAuthRetry(with host: HostItem) {
        let result = AuthRetryResult(password: host.loadPassword() ?? "", privateKeyPEM: host.loadPrivateKey() ?? "", certificatePEM: host.loadCertificate() ?? "", secureEnclaveTag: host.loadSecureEnclaveKeyTag(), credentialID: host.credentialRef?.persistentModelID, authType: host.authType)
        completeAuthRetry(with: result)
    }

    func cancelAuthRetry() {
        authRetryContinuation?.resume(returning: nil)
        authRetryContinuation = nil
        authRetryRequest = nil
    }

    /// Typed auth failure from reconnect PTY (not via setupPTYSession) must show sheet
    /// Citadel throws sync, OpenSSH tails async; Prompts=1 fails fast to sheet
    private func handleServiceAuthFailure(_ failure: SSHFailure, for tab: TerminalTab) async {
        guard tabs.contains(where: { $0.id == tab.id }), let session = tab.session else { return }
        guard case .authentication(let authFailure) = failure else { return }
        let display = SSHErrorMessageParser.explain(authFailure.message, host: tab.hostItem.host, jumpHost: tab.hostItem.jumpHostRef?.host) ?? authFailure.message
        // Single sheet path
        if case .authentication = session.failureReason, session.phase == .failed(display), isShowingDialog(for: tab.id) { return }
        session.failureReason = failure
        setPhase(session, to: .failed(display), host: tab.hostItem.host, engine: "OpenSSH", reason: "authFailed")
        session.signalAuthFailure()
        session.errorMessage = display
        Log.session.error("[SSH_FAILURE] type=authentication backend=openssh (service) msg=\(display.prefix(120), privacy: .public)")
        Log.session.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed (service)")
        guard !isShowingDialog(for: tab.id) else { return }
        setShowingDialog(true, for: tab.id)
        defer { setShowingDialog(false, for: tab.id) }
        if retryState(for: tab.id) == .dialogShown {
            Log.session.error("[AUTH_RETRY] service reconnect failed; cleaning")
            OpenSSHBackend.cleanupOrphanedMuxes()
            setRetryState(.cleanupDone, for: tab.id)
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            sessionStore.markConnected(tab.id)
            let reuse = transientAuthResults[tab.id]
            if let reuseResult = reuse, reuseResult.authType == .password, !reuseResult.password.isEmpty {
                await connectTab(tab, passwordOverride: reuseResult.password, ephemeralResult: reuseResult, resetAuthRetry: false)
            } else {
                await connectTab(tab, ephemeralResult: reuse, resetAuthRetry: false)
            }
            if case .failed = tab.session?.phase {
                // Keep cleanupDone for next failure
            } else {
                setRetryState(.idle, for: tab.id)
            }
            return
        }
        if retryState(for: tab.id) == .cleanupDone {
            Log.session.error("[AUTH_RETRY] service second failure; re-show sheet")
            setRetryState(.idle, for: tab.id)
        }
        setRetryState(.dialogShown, for: tab.id)
        guard let result = await requestAuthRetry(for: tab, rawError: authFailure.message) else {
            setRetryState(.idle, for: tab.id); return
        }
        let passwordLength = result.password.count
        let fingerprint = passwordLength>0 ? OpenSSHBackend.passwordFingerprint(result.password) : "-"
        Log.session.info("[AUTH_RETRY] source=ephemeral (service) passwordLength=\(passwordLength) passwordFingerprint=\(fingerprint, privacy: .public) authType=\(result.authType.rawValue, privacy: .public)")
        transientAuthResults[tab.id] = result
        // Isolated retry via ControlMaster bypass
        if result.authType == .password, !result.password.isEmpty {
            await connectTab(tab, passwordOverride: result.password, ephemeralResult: result, resetAuthRetry: false)
        } else {
            await connectTab(tab, ephemeralResult: result, resetAuthRetry: false)
        }
        if case .failed = tab.session?.phase {
            transientAuthResults[tab.id] = nil
        } else {
            setRetryState(.idle, for: tab.id)
        }
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
                    if case .authentication = session.failureReason { return }
                    let displayForPhase = SSHErrorMessageParser.explain(message, host: tab.hostItem.host, jumpHost: tab.hostItem.jumpHostRef?.host) ?? message
                    let isAuth = Self.isAuthFailure(message) || Self.isAuthFailure(displayForPhase)
                    guard isAuth else {
                        session.errorMessage = message
                        Log.session.error("[AUTH] not an auth failure, no dialog: \(message.prefix(120))")
                        return
                    }
                    await service.suppressRecoveryForAuth()
                    session.failureReason = .authentication(.permissionDenied(displayForPhase))
                    self.setPhase(session, to: .failed(displayForPhase), host: tab.hostItem.host, engine: "OpenSSH", reason: "authFailed")
                    session.signalAuthFailure()
                    session.errorMessage = displayForPhase
                    Log.session.error("[AUTH] OpenSSH authFailed -> failed: \(displayForPhase.prefix(120), privacy: .public)")
                }
            },
            onFailure: { [weak self, weak tab] failure in
                Task { @MainActor in
                    guard let self, let tab else { return }
                    switch failure {
                    case .authentication(let authFailure):
                        await service.suppressRecoveryForAuth()
                        session.failureReason = failure
                        let display = SSHErrorMessageParser.explain(authFailure.message, host: tab.hostItem.host, jumpHost: tab.hostItem.jumpHostRef?.host) ?? authFailure.message
                        self.setPhase(session, to: .failed(display), host: tab.hostItem.host, engine: "OpenSSH", reason: "authFailed")
                        session.signalAuthFailure()
                        session.errorMessage = display
                        Log.session.error("[SSH_FAILURE] type=authentication backend=openssh msg=\(display.prefix(120), privacy: .public)")
                        Log.session.debug("[RECOVERY_GATE] blocked authFailed (dedup sheet via handleServiceAuthFailure)")
                        
                    case .hostKey(let msg):
                        await service.suppressRecoveryForAuth()
                        session.failureReason = failure
                        self.setPhase(session, to: .failed(msg), host: tab.hostItem.host, engine: "OpenSSH", reason: "hostKey")
                        session.errorMessage = msg
                        Log.session.info("[RECOVERY_GATE] blocked=true reason=hostKey")
                    case .cancelled:
                        session.failureReason = .cancelled
                        Log.session.info("[RECOVERY_GATE] blocked=true reason=cancelled")
                    case .transport(let transportFailure):
                        session.failureReason = failure
                        Log.session.info("[RECOVERY_GATE] blocked=false reason=transportFailed detail=\(transportFailure.message.prefix(80), privacy: .public)")
                    case .unknown(let message):
                        session.failureReason = failure
                        Log.session.warning("[SSH_FAILURE] type=unknown msg=\(message.prefix(80), privacy: .public)")
                    }
                }
            }
        )
        Log.session.info("[PTY] PTY session opened successfully")

        guard tabs.contains(where: { $0.id == tab.id }) else {
            Log.session.warning("[PTY] Tab was closed during PTY setup, aborting")
            throw SSHServiceError.connectionFailed("Tab was closed during PTY setup")
        }

        // Close old PTy if retry (fixes hang at banner after password retry)
        pane.ptySession?.close()
        session.ptySession?.close()
        pane.ptySession = ptySession
        session.ptySession = ptySession // Keep for backward compatibility
        ptySession.teamSessionID = TeamSessionID(tabID: tab.id, paneID: pane.id)
        ptySession.hostItem = tab.hostItem
        Log.session.info("[PTY] PTY session assigned to pane")

        // Direct rebind for immediate refresh (fixes retry hang where Notification is coalesced)
        TerminalViewCache.shared.rebindOutputStream(for: pane.id, to: ptySession)
        TerminalViewCache.shared.rebindOutputStream(for: tab.id, to: ptySession)
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
        let capturedGen = session.generation
        session.stateObservationTask = Task { [weak self, weak tab, weak session] in
            guard let self, let tab, let session else { return }
            for await state in service.stateStream {
                guard !Task.isCancelled else { break }
                guard session.stateObserverToken == token else { return }
                guard tab.session === session else { break }
                // Generation isolation: discard stale state
                guard session.generation == capturedGen else {
                    Log.session.info("[OBSERVER] discard stale state gen=\(capturedGen.uuidString.prefix(8)) != current=\(session.generation.uuidString.prefix(8))")
                    return
                }

                switch state {
                case .connected:
                    if let newPTY = await service.consumePendingPTY() {
                        if let firstPane = tab.layout.root.paneState {
                            let oldPTY = firstPane.ptySession
                            newPTY.teamSessionID = TeamSessionID(tabID: tab.id, paneID: firstPane.id)
                            newPTY.hostItem = tab.hostItem
                            // Fix 2: ensure output binding before closing old (make-before-break)
                            firstPane.ptySession = newPTY
                            session.ptySession = newPTY
                            TerminalViewCache.shared.rebindOutputStream(for: tab.id, to: newPTY)
                            TerminalViewCache.shared.rebindOutputStream(for: firstPane.id, to: newPTY)
                            // Fix 1: log stages
                            Log.session.info("[RECOVERY_STEP] ptyReady=true outputBound=true pane=\(firstPane.id.uuidString.prefix(8), privacy: .public)")
                            syncPTYSize(for: firstPane.id, ptySession: newPTY)
                            // Close old only after new is bound
                            oldPTY?.close()
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
                ptySession.hostItem = tab.hostItem
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
