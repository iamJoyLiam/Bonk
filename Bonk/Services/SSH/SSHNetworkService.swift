//
//  SSHNetworkService.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

@preconcurrency import Citadel
import Crypto
import Foundation
import Network
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import os.log

// MARK: - SSHNetworkService

/// Core SSH connection service, isolated as a Swift Actor.
///
/// All mutable state is actor-isolated, guaranteeing data-race freedom.
/// Provides password / private-key authentication, TOFU host key verification,
/// PTY-based interactive shell streams, and automatic reconnection with
/// exponential backoff + jitter.
public actor SSHNetworkService {
    public internal(set) var connectionState: SSHConnectionState = .disconnected

    /// State stream for external observation (SessionManager subscribes to this).
    public let stateStream: AsyncStream<SSHConnectionState>
    let stateContinuation: AsyncStream<SSHConnectionState>.Continuation

    /// Expose client for port forwarding. Returns nil if not connected.
    public var sshClient: SSHClient? {
        client
    }

    var client: SSHClient?
    /// Separate native Citadel connection used only by legacy SFTP flow when
    /// the terminal transport is system OpenSSH.
    private var sftpNativeClient: SSHClient?
    var config: SSHConnectionConfig?
    var activePTYSession: PTYSession?
    /// Called with a manually typed password the server accepted, so the
    /// saved credential can be refreshed.
    private var onManualPasswordVerified: (@Sendable (String) -> Void)?

    /// Actor-safe way to install the manual-password handler (this type is
    /// an actor, so callers cannot assign properties directly).
    public func setManualPasswordHandler(_ handler: (@Sendable (String) -> Void)?) {
        onManualPasswordVerified = handler
    }

    #if os(macOS)
        /// System OpenSSH transport for macOS terminal/exec/forwarding auth.
        var openSSHBackend: OpenSSHBackend?
    #endif
    var usesOpenSSHTransport = false
    let keepAlive = SSHKeepAlive()
    /// Per-session supervisor - replaces isHandlingDisconnect Bool with state machine per P0 spec.
    let supervisor = SSHConnectionSupervisor()
    private var wakeMonitorTask: Task<Void, Never>?
    /// ConnectionAttemptID per hard constraint 3 - old callbacks with stale ID are discarded
    let attemptIDBox = NIOLockedValueBox<UUID>(UUID())
    var currentAttemptID: UUID {
        get { attemptIDBox.withLockedValue { $0 } }
        set { attemptIDBox.withLockedValue { $0 = newValue } }
    }

    /// Current reconnection loop, so manual disconnect/reconnect can cancel it.
    private var reconnectTask: Task<Void, Never>?

    /// Network monitor for detecting connectivity changes.
    var networkMonitor: NWPathMonitor?
    var isMonitoringNetwork = false
    var lastNetworkPathWasSatisfied: Bool?
    /// Whether we're waiting for network to come back (for delayed reconnect).
    var isWaitingForNetwork = false

    /// Stores PTY parameters for reconnection.
    struct PTYConfig {
        let cols: Int
        let rows: Int
        let termType: String
    }

    var lastPTYConfig: PTYConfig?
    var lastSuccessfulConnectionAt: Date?
    /// Last typed failure for gate & debug — set by handleTypedFailure
    var pendingFailure: SSHFailure?
    /// Write-failure recovery tracking: probe-alive after a channel write failure does not
    /// recreate the channel, so a half-dead channel passes the probe forever while every
    /// keystroke fails. Count consecutive write-failure/probe-alive cycles and escalate to
    /// a full reconnect instead of restoring the UI in a loop.
    private var pendingWriteFailureValidation = false
    private var consecutiveWriteFailedAliveCycles = 0
    private static let maxWriteFailedAliveCycles = 3
    /// Callback for SessionManager to present AuthRetrySheet on typed auth failure (including reconnect PTYs)
    private var onAuthFailureHandler: (@Sendable (SSHFailure) -> Void)?

    /// PTY session created after reconnect — SessionManager consumes this.
    public internal(set) var pendingPTYSession: PTYSession?

    let hostKeyStore: any SSHHostKeyStore
    /// VNext — forced backend for Hybrid routing (T2.2). When set, overrides shouldUseOpenSSH.
    var vnextForcedBackend: SSHBackendType?

    public init(hostKeyStore: some SSHHostKeyStore) {
        self.hostKeyStore = hostKeyStore
        var cont: AsyncStream<SSHConnectionState>.Continuation!
        (stateStream, cont) = AsyncStream<SSHConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateContinuation = cont
    }

    deinit {
        stateContinuation.finish()
    }

    /// Consume the pending PTY session (from reconnect). Returns nil if none.
    public func consumePendingPTY() -> PTYSession? {
        let session = pendingPTYSession
        pendingPTYSession = nil
        return session
    }

    /// Enable auto-reconnection after initial connection succeeds.
    public func enableReconnection(attempts: Int = 3) {
        guard var config else { return }
        // Previously disabled for OpenSSH to avoid re-prompting password/MFA.
        // Now enabled for both engines; handleDisconnect distinguishes
        // interactive auth failures (no reconnect) from network drops (reconnect).
        let resolvedAttempts = attempts
        config = SSHConnectionConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            jumpHost: config.jumpHost,
            maxReconnectAttempts: resolvedAttempts,
            baseReconnectDelay: config.baseReconnectDelay,
            algorithmRequirements: config.algorithmRequirements,
            bypassControlMaster: config.bypassControlMaster,
            generation: config.generation
        )
        self.config = config
    }

    // MARK: - Connect

    /// Connection timeout — prevents hanging on unreachable hosts.
    static let connectionTimeoutSeconds: Int = 10

    public func connect(config: SSHConnectionConfig) async throws {
        Log.ssh.info("[CONNECT] Starting connect to \(config.host):\(config.port)")
        guard !connectionState.isConnected else {
            Log.ssh.warning("[CONNECT] Already connected, throwing alreadyConnected")
            throw SSHServiceError.alreadyConnected
        }

        self.config = config
        pendingFailure = nil
        // Forward generation if present else new
        if let gen = config.generation { currentAttemptID = gen } else { currentAttemptID = UUID() }
        // — 60s gate  authentication ，/Ephemeral
        await supervisor.reset()
        Log.ssh.info("[CONNECT] new attemptID=\(self.currentAttemptID.uuidString.prefix(8), privacy: .public) host=\(config.host, privacy: .public) gen=\(config.generation?.uuidString.prefix(8) ?? "nil", privacy: .public)")
        usesOpenSSHTransport = false
        try? await sftpNativeClient?.close()
        sftpNativeClient = nil
        #if os(macOS)
            openSSHBackend?.close()
            openSSHBackend = nil
        #endif
        connectionState = .connecting
        stateContinuation.yield(.connecting)
        Log.ssh.info("[CONNECT] State set to .connecting")

        do {
            #if os(macOS)
                if shouldUseOpenSSH(config.authMethod) {
                    let backend = try OpenSSHBackend(config: config)
                    openSSHBackend = backend
                    usesOpenSSHTransport = true
                    // No optimistic connected; ready after PTY gate
                    Log.ssh.info("[CONNECT] Using system OpenSSH transport (pending PTY, not yet connected)")
                    configureSupervisorForCurrentConnection()
                    startWakeMonitoring()
                    startNetworkMonitor()
                    return
                }
            #endif

            Log.ssh.info("[CONNECT] Calling establishConnection with \(Self.connectionTimeoutSeconds)s timeout...")

            // Wrap with timeout to prevent hanging on unreachable hosts
            try await withThrowingTimeout(of: .seconds(Self.connectionTimeoutSeconds)) {
                try await self.establishConnection(config: config)
            }

            Log.ssh.info("[CONNECT] establishConnection returned successfully")

            guard let client else {
                Log.ssh.error("[CONNECT] Client is nil after successful connection")
                throw SSHServiceError.connectionFailed("Connection established but client is nil")
            }

            Log.ssh.info("[CONNECT] Starting keepAlive...")
            let keepAliveAttemptID = currentAttemptID
            await keepAlive.settimeoutHandler { [weak self] in
                guard let self, self.attemptIDBox.withLockedValue { $0 } == keepAliveAttemptID else {
                    Log.ssh.info("[RECOVERY] discard stale keepAlive old=\(keepAliveAttemptID.uuidString.prefix(8), privacy: .public)")
                    return
                }
                Task { await self.supervisor.requestRecovery(reason: .keepAliveTimeout) }
            }
            await keepAlive.start(client: client)
            Log.ssh.info("[CONNECT] keepAlive started, connection complete")
            startNetworkMonitor()
            configureSupervisorForCurrentConnection()
            startWakeMonitoring()
        } catch {
            Log.ssh.error("[CONNECT] Connection failed: \(error.localizedDescription)")

            client = nil
            try? await sftpNativeClient?.close()
            sftpNativeClient = nil
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)

            // Don't retry fatal errors
            if let sshError = error as? SSHServiceError {
                switch sshError {
                case .hostKeyMismatch:
                    Log.ssh.error("[CONNECT] Host key mismatch, not retrying")
                    throw sshError
                default:
                    break
                }
            }

            // Map timeout to user-friendly error
            if error is SSHTimeoutError {
                throw SSHServiceError.connectionFailed(
                    "Connection timed out after \(Self.connectionTimeoutSeconds)s. Check host and network."
                )
            }

            if config.maxReconnectAttempts > 0 {
                Log.ssh.info("[CONNECT] Attempting reconnection...")
                startReconnect()
            } else {
                throw SSHServiceError.connectionFailed(String(describing: error))
            }
        }
    }

    /// Shared SSH connection logic used by both connect() and reconnect().
    func establishConnection(config: SSHConnectionConfig) async throws {
        let sshClient = try await makeNativeClient(config: config)
        client = sshClient
        connectionState = .connected
        stateContinuation.yield(.connected)
        Log.ssh.info("[ESTABLISH] State set to .connected, starting disconnect monitor")
        startMonitoringDisconnect(sshClient)
    }

    /// Build and verify one native Citadel client without changing primary
    /// terminal connection state. Used to keep existing SFTP behavior stable
    /// while macOS terminal sessions use OpenSSH.
    private func makeNativeClient(config: SSHConnectionConfig) async throws -> SSHClient {
        Log.ssh.info("[ESTABLISH] Mapping auth method...")
        let citadelAuth = try mapAuthMethod(config.authMethod, username: config.username)
        Log.ssh.info("[ESTABLISH] Auth method mapped, setting up host key validator...")
        let fingerprintBox = NIOLockedValueBox<SSHHostFingerprint?>(nil)

        let validator = HostKeyValidator { key in
            var buffer = ByteBuffer()
            key.write(to: &buffer)
            let bytes = Data(buffer.readableBytesView)
            let digest = SHA256.hash(data: bytes)
            let b64 = Data(digest).base64EncodedString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            fingerprintBox.withLockedValue { $0 = SSHHostFingerprint(hash: "SHA256:\(b64)") }
        }

        Log.ssh.info("[ESTABLISH] Calling SSHClient.connect to \(config.host):\(config.port)...")
        let sshClient = try await SSHClient.connect(
            host: config.host,
            port: Int(config.port),
            authenticationMethod: citadelAuth,
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            algorithms: .all
        )
        Log.ssh.info("[ESTABLISH] SSHClient.connect returned successfully")

        Log.ssh.info("[ESTABLISH] Verifying host key...")
        do {
            try await verifyHostKey(
                host: config.host,
                port: config.port,
                fingerprint: fingerprintBox.withLockedValue { $0 },
                store: hostKeyStore
            )
        } catch {
            // Do not leak the established connection when verification fails.
            try? await sshClient.close()
            throw error
        }
        Log.ssh.info("[ESTABLISH] Host key verified")
        return sshClient
    }

    // MARK: - Exec

    /// Execute a command via a separate SSH exec channel (no PTY).
    /// Only ready allows exec to avoid stdin race.
    /// Returns clean stdout with no ANSI codes, no prompt, no echo.
    public func executeCommand(
        _ command: String,
        registerHandle: (@Sendable (any CommandExecutionHandle) -> Void)? = nil
    ) async throws -> String {
        guard case .connected = connectionState else {
            throw SSHServiceError.notConnected
        }
        #if os(macOS)
            if usesOpenSSHTransport, let openSSHBackend {
                // Commands normally finish in seconds; a half-open connection
                // would hang this forever, so bound it.
                return try await withThrowingTimeout(of: .seconds(30)) {
                    try await openSSHBackend.executeCommand(command, registerHandle: registerHandle)
                }
            }
        #endif
        guard !usesOpenSSHTransport else {
            throw SSHServiceError.connectionFailed("OpenSSH transport is unavailable on this platform.")
        }
        guard let client else { throw SSHServiceError.notConnected }
        let response = try await client.executeCommand(command)
        return String(buffer: response).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SFTP

    /// Open the existing native SFTP flow.
    ///
    /// macOS OpenSSH sessions use `openOpenSSHSFTPClient()` instead, so this
    /// Citadel path remains for Secure Enclave and non-OpenSSH transports.
    public func openSFTPClient() async throws -> SFTPClient {
        #if os(macOS)
            if usesOpenSSHTransport {
                guard let config else { throw SSHServiceError.notConnected }
                if let existingClient = sftpNativeClient, existingClient.isConnected {
                    do {
                        return try await existingClient.openSFTP()
                    } catch {
                        try? await existingClient.close()
                        sftpNativeClient = nil
                    }
                }

                let nativeClient = try await makeNativeClient(config: config)
                do {
                    let sftp = try await nativeClient.openSFTP()
                    sftpNativeClient = nativeClient
                    return sftp
                } catch {
                    try? await nativeClient.close()
                    throw error
                }
            }
        #endif
        guard let client else { throw SSHServiceError.notConnected }
        return try await client.openSFTP()
    }

    #if os(macOS)
        /// Return the OpenSSH-backed SFTP client for macOS OpenSSH sessions.
        /// Returns nil when the active transport is native Citadel.
        func openOpenSSHSFTPClient() throws -> OpenSSHSFTPClient? {
            guard usesOpenSSHTransport else { return nil }
            guard let openSSHBackend else { throw SSHServiceError.notConnected }
            return openSSHBackend.makeSFTPClient()
        }
    #endif

    // MARK: - PTY

    public func openPTY(
        cols: Int = 80,
        rows: Int = 24,
        termType: String = "xterm-256color",
        onError: (@Sendable (String) -> Void)? = nil,
        onFailure: (@Sendable (SSHFailure) -> Void)? = nil
    ) async throws -> PTYSession {
        let capturedAttemptID = currentAttemptID
        #if os(macOS)
            if usesOpenSSHTransport, let openSSHBackend {
                openSSHBackend.onManualPasswordVerified = onManualPasswordVerified
                let session = try openSSHBackend.openPTY(
                    cols: cols,
                    rows: rows,
                    termType: termType
                ) { [weak self] in
                    guard let self, self.attemptIDBox.withLockedValue { $0 } == capturedAttemptID else {
                        Log.ssh.info("[RECOVERY] discard stale HUP old=\(capturedAttemptID.uuidString.prefix(8), privacy: .public)")
                        return
                    }
                    Task { await self.handleDisconnect() }
                } onError: { message in
                    Task { @MainActor in
                        onError?(message)
                    }
                } onFailure: { [weak self] failure in
                    Task { await self?.handleTypedFailure(failure) }
                    Task { @MainActor in onFailure?(failure) }
                    // legacy bridge: also forward String for existing SessionManager handler
                    Task { @MainActor in onError?(failure.message) }
                }
                lastPTYConfig = PTYConfig(cols: cols, rows: rows, termType: termType)
                activePTYSession = session
                lastSuccessfulConnectionAt = Date()
                session.onWriteFailed = { [weak self] in
                    guard let self, self.attemptIDBox.withLockedValue { $0 } == capturedAttemptID else { return }
                    Task { await self.handlePTYWriteFailed() }
                }
                return session
            }
        #endif

        guard let client else { throw SSHServiceError.notConnected }

        lastPTYConfig = PTYConfig(cols: cols, rows: rows, termType: termType)
        lastSuccessfulConnectionAt = Date()
        let session = PTYSession()
        session.generation = capturedAttemptID
        session.onWriteFailed = { [weak self] in
            guard let self, self.attemptIDBox.withLockedValue { $0 } == capturedAttemptID else { return }
            Task { await self.handlePTYWriteFailed() }
        }
        session.start(client: client, cols: cols, rows: rows, termType: termType)
        activePTYSession = session
        return session
    }

    /// Resize the active PTY session.
    public func resizePTY(cols: Int, rows: Int) async throws {
        guard let activePTYSession else { return }
        try await activePTYSession.resize(cols: cols, rows: rows)
    }

    // MARK: - Disconnect

    /// Public recovery entry for SessionManager userRequested - per-session isolation, idempotent per P0.
    public func requestRecovery(reason: RecoveryReason) async {
        await supervisor.requestRecovery(reason: reason)
    }

    /// Input write hit a dead channel — surface the reconnecting spinner via
    /// the state stream immediately. Without this the supervisor's probe phase
    /// (≤5s) leaves the UI on "connected" while keystrokes fail. If the probe
    /// finds the connection alive, onProbedAlive restores .connected.
    private func presentReconnectingForChannelLost() {
        let maxAttempts = max(config?.maxReconnectAttempts ?? 0, ReconnectPolicy.default.maxAttempts)
        connectionState = .reconnecting(attempt: 1, maxAttempts: maxAttempts)
        stateContinuation.yield(.reconnecting(attempt: 1, maxAttempts: maxAttempts))
        Log.ssh.warning("[RECOVERY_UI] input channel lost -> reconnecting spinner")
    }

    /// Funnel for PTY write failures: flip the state stream to the reconnecting
    /// spinner first, then run supervisor recovery (probe → reconnect).
    func handlePTYWriteFailed() {
        pendingWriteFailureValidation = true
        // Throttle the UI flip: the supervisor pipeline is idempotent, but every
        // keystroke on a dead channel would otherwise re-trigger the spinner.
        if !isReconnecting {
            presentReconnectingForChannelLost()
        }
        Task { await supervisor.requestRecovery(reason: .writeFailed) }
    }

    /// Whether the connection state stream is already showing reconnecting.
    private var isReconnecting: Bool {
        if case .reconnecting = connectionState { return true }
        return false
    }

    /// Probe reported alive. If a channel write failure is pending validation, the probe
    /// only proved the transport is up — the channel itself may still be half-dead.
    /// Escalate to a full reconnect (recreates the PTY) after repeated cycles instead
    /// of restoring the UI and failing on the next keystroke.
    private func handleProbeAlive() async {
        guard pendingWriteFailureValidation else {
            consecutiveWriteFailedAliveCycles = 0
            return
        }
        pendingWriteFailureValidation = false
        consecutiveWriteFailedAliveCycles += 1
        guard consecutiveWriteFailedAliveCycles >= Self.maxWriteFailedAliveCycles else {
            restoreConnectedAfterProbeAlive()
            return
        }
        consecutiveWriteFailedAliveCycles = 0
        Log.ssh.warning("[RECOVERY] channel write still failing after probe alive — full reconnect")
        if await performSingleReconnect() {
            restoreConnectedAfterProbeAlive()
        } else {
            await supervisor.requestRecovery(reason: .writeFailed)
        }
    }

    /// Probe found the transport alive — undo the optimistic reconnecting
    /// spinner presented by handlePTYWriteFailed (transient write failure).
    private func restoreConnectedAfterProbeAlive() {
        if case .reconnecting = connectionState {
            connectionState = .connected
            stateContinuation.yield(.connected)
            Log.ssh.info("[RECOVERY_UI] probe alive -> restore connected")
        }
    }

    /// Supervisor notified of a new reconnect attempt — update connection state and UI stream.
    private func updateReconnectingState(attempt: Int, maxAttempts: Int) {
        connectionState = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
        stateContinuation.yield(.reconnecting(attempt: attempt, maxAttempts: maxAttempts))
        Log.ssh.info("[RECOVERY_UI] reconnecting attempt=\(attempt)/\(maxAttempts)")
    }

    /// All reconnect attempts exhausted — transition connection state to disconnected.
    private func handleRecoveryExhausted() {
        connectionState = .disconnected
        stateContinuation.yield(.disconnected)
        Log.ssh.warning("[RECOVERY_UI] recovery exhausted -> disconnected")
    }

    /// Set handler for typed auth failures — SessionManager presents AuthRetrySheet (also for reconnect PTYs)
    public func setAuthFailureHandler(_ handler: (@Sendable (SSHFailure) -> Void)?) {
        onAuthFailureHandler = handler
    }

    /// Auth failure gate — cancel any recovery and forbid supervisor auto-retry until next connect.
    public func suppressRecoveryForAuth() async {
        await supervisor.suppressRecoveryForAuth()
    }

    /// Typed failure handler — central Recovery gate logging
    func handleTypedFailure(_ failure: SSHFailure) async {
        switch failure {
        case let .authentication(authFailure):
            Log.ssh.info("[SSH_FAILURE] type=authentication backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public) detail=\(authFailure.message.prefix(120), privacy: .public)")
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed")
            await self.suppressRecoveryForAuth()
            self.pendingFailure = failure
            self.stopWakeMonitoring()
            // SessionManager  sheet reconnect PTY
            if let handler = self.onAuthFailureHandler { handler(failure) }
        case let .hostKey(hostKeyMessage):
            Log.ssh.info("[SSH_FAILURE] type=hostKey backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public) msg=\(hostKeyMessage.prefix(80), privacy: .public)")
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=hostKey")
            await self.suppressRecoveryForAuth()
            self.pendingFailure = failure
            self.stopWakeMonitoring()
        case .cancelled:
            Log.ssh.info("[SSH_FAILURE] type=cancelled backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public)")
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=cancelled")
            await self.supervisor.suppressRecoveryForAuth()
            self.pendingFailure = failure
        case let .transport(transportFailure):
            Log.ssh.info("[SSH_FAILURE] type=transport backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public) detail=\(transportFailure.message.prefix(120), privacy: .public)")
            Log.ssh.info("[RECOVERY_GATE] blocked=false reason=transportFailed")
            self.pendingFailure = failure
        case let .unknown(unknownMessage):
            Log.ssh.info("[SSH_FAILURE] type=unknown backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public) msg=\(unknownMessage.prefix(80), privacy: .public)")
            self.pendingFailure = failure
        }
    }

    public func disconnect() async {
        await keepAlive.stop()
        await supervisor.reset()
        stopWakeMonitoring()

        stopNetworkMonitor()
        reconnectTask?.cancel()
        reconnectTask = nil

        activePTYSession?.close()
        activePTYSession = nil

        #if os(macOS)
            openSSHBackend?.close()
            openSSHBackend = nil
        #endif
        usesOpenSSHTransport = false

        try? await sftpNativeClient?.close()
        sftpNativeClient = nil
        try? await client?.close()
        client = nil

        connectionState = .disconnected
        stateContinuation.yield(.disconnected)
        config = nil
    }

    // MARK: - Reconnection State Machine

    private func startReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { await self.reconnect() }
    }

    /// Single reconnect loop — one policy, one watermark, one phase stream.
    /// `usesOpenSSHTransport` selects the attempt body; backoff + state + PTY rebind are shared.
    private func reconnect() async {
        guard let config else { return }
        let policy = ReconnectPolicy.default
        let maxAttempts = max(config.maxReconnectAttempts, policy.maxAttempts)
        var attempt = 0
        while attempt < maxAttempts, !Task.isCancelled {
            connectionState = .reconnecting(attempt: attempt + 1, maxAttempts: maxAttempts)
            stateContinuation.yield(.reconnecting(attempt: attempt + 1, maxAttempts: maxAttempts))
            let delay = policy.delay(for: attempt)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { break }
            do {
                if usesOpenSSHTransport {
                    // Extreme: no sleep for ControlMaster re-create
                    try? await Task.sleep(for: .milliseconds(1))
                    let backend = try OpenSSHBackend(config: config)
                    openSSHBackend = backend
                    usesOpenSSHTransport = true
                    connectionState = .connected
                    stateContinuation.yield(.connected)
                    Log.ssh.info("[RECONNECT] OpenSSH reconnect succeeded attempt \(attempt + 1)")
                    stopNetworkMonitor()
                    startNetworkMonitor()
                    if let ptyConfig = lastPTYConfig {
                        do {
                            let session = try backend.openPTY(
                                cols: ptyConfig.cols, rows: ptyConfig.rows, termType: ptyConfig.termType
                            ) { [weak self] in Task { await self?.handleDisconnect() } } onError: { _ in }
                            activePTYSession = session
                            pendingPTYSession = session
                            Log.ssh.info("[RECONNECT] OpenSSH PTY re-created \(ptyConfig.cols)x\(ptyConfig.rows)")
                        } catch {
                            Log.ssh.warning("[RECONNECT] OpenSSH PTY re-create failed: \(error.localizedDescription)")
                        }
                    }
                } else {
                    // Native Citadel path: bound handshake + keepalive re-arm
                    try await withThrowingTimeout(of: .seconds(Self.connectionTimeoutSeconds)) {
                        try await self.establishConnection(config: config)
                    }
                    stopNetworkMonitor()
                    startNetworkMonitor()
                    await keepAlive.settimeoutHandler { [weak self] in
                        guard let self else { return }
                        Task { await self.handleDisconnect() }
                    }
                    if let client {
                        await keepAlive.start(client: client)
                    }
                    if let ptyConfig = lastPTYConfig, let client {
                        let session = PTYSession()
                        session.start(client: client, cols: ptyConfig.cols, rows: ptyConfig.rows, termType: ptyConfig.termType)
                        activePTYSession = session
                        pendingPTYSession = session
                    }
                }
                return
            } catch is CancellationError {
                break
            } catch let error as SSHServiceError {
                // Fatal errors: don't retry (both transports)
                switch error {
                case .hostKeyMismatch, .alreadyConnected:
                    Log.ssh.error("Fatal SSH error, aborting reconnect: \(error.localizedDescription)")
                    if usesOpenSSHTransport {
                        connectionState = .disconnected
                        stateContinuation.yield(.disconnected)
                    }
                    return
                case .notConnected, .connectionFailed, .reconnectExhausted:
                    Log.ssh.warning("Recoverable SSH error (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                    attempt += 1
                }
            } catch is SSHTimeoutError {
                Log.ssh.warning("Reconnect attempt \(attempt + 1)/\(maxAttempts) timed out")
                attempt += 1
            } catch {
                Log.ssh.warning("Reconnect attempt \(attempt + 1)/\(maxAttempts) failed: \(error.localizedDescription)")
                attempt += 1
            }
        }
        if !Task.isCancelled {
            usesOpenSSHTransport = false
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)
            Log.ssh.error("Reconnect exhausted after \(maxAttempts) attempts")
        }
    }

    /// Legacy entry kept for external callers — now forwards to single `reconnect()`.
    private func reconnectOpenSSH(config _: SSHConnectionConfig) async {
        await reconnect()
    }

    // MARK: - Disconnect Monitor

    private func startMonitoringDisconnect(_ sshClient: SSHClient) {
        let capturedID = currentAttemptID
        sshClient.onDisconnect { [weak self] in
            guard let self else { return }
            guard self.attemptIDBox.withLockedValue { $0 } == capturedID else {
                Log.ssh.info("[RECOVERY] discard stale disconnect old=\(capturedID.uuidString.prefix(8), privacy: .public)")
                return
            }
            Task { await self.handleDisconnect() }
        }
    }

    func handleDisconnect() async {
        if let typedFailure = pendingFailure {
            switch typedFailure {
            case .authentication, .hostKey, .cancelled:
                Log.ssh.info("[RECOVERY_GATE] blocked=true reason=\(typedFailure.typeString, privacy: .public) handleDisconnect suppressed backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public)")
                return
            case .transport, .unknown: break
            }
        }
        guard let config else { return }
        guard config.maxReconnectAttempts > 0 else {
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)
            return
        }
        await supervisor.requestRecovery(reason: .channelClosed)
    }

    public func lastTypedFailure() -> SSHFailure? {
        pendingFailure
    }

    public func clearTypedFailure() {
        pendingFailure = nil; lastSuccessfulConnectionAt = nil
    }

    // MARK: - P0 Wake & Probe Integration

    private func configureSupervisorForCurrentConnection() {
        guard let config else { return }
        pendingWriteFailureValidation = false
        consecutiveWriteFailedAliveCycles = 0
        let hostLabel = "\(config.username)@\(config.host):\(config.port)"
        let engineLabel = usesOpenSSHTransport ? "openssh" : "citadel"
        let maxAttempts = max(config.maxReconnectAttempts, ReconnectPolicy.default.maxAttempts)
        Task {
            await supervisor.configure(
                host: hostLabel,
                engine: engineLabel,
                maxAttempts: maxAttempts,
                probe: { [weak self] in
                    guard let self else { return false }
                    return await self.probeLiveness()
                },
                reconnect: { [weak self] in
                    guard let self else { return false }
                    return await self.performSingleReconnect()
                },
                onProbedAlive: { [weak self] in
                    guard let self else { return }
                    // Probe alive -> transport is healthy. If a channel write failure is
                    // pending, validate the channel instead of blindly restoring .connected.
                    Log.ssh.info("[RECOVERY] probe alive keep ready host=\(hostLabel, privacy: .public)")
                    Task { await self.handleProbeAlive() }
                    Task { await self.supervisor.reset() }
                },
                onReconnecting: { [weak self] attempt, limit in
                    guard let self else { return }
                    Task { await self.updateReconnectingState(attempt: attempt, maxAttempts: limit) }
                },
                onExhausted: { [weak self] in
                    guard let self else { return }
                    Task { await self.handleRecoveryExhausted() }
                }
            )
        }
    }

    private func startWakeMonitoring() {
        #if os(macOS)
            wakeMonitorTask?.cancel()
            wakeMonitorTask = Task { [weak self] in
                guard let self else { return }
                for await event in SystemWakeMonitor.shared.events {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case let .systemWake(_, duration):
                        Log.ssh.info("[WAKE] systemWake -> probe sleepDuration=\(duration ?? -1, privacy: .public)")
                        await self.supervisor.requestRecovery(reason: .wakeProbeFailed(sleepDuration: duration))
                    case .appDidBecomeActive:
                        Log.ssh.debug("[WAKE] appDidBecomeActive -> probe")
                        await self.supervisor.requestRecovery(reason: .wakeProbeFailed(sleepDuration: nil))
                    default:
                        break
                    }
                }
            }
        #endif
    }

    private func stopWakeMonitoring() {
        wakeMonitorTask?.cancel()
        wakeMonitorTask = nil
    }

    /// Liveness probe per hard constraint 1: Transport alive != Session/PTY ready.
    /// OpenSSH: check ControlMaster then validate PTY; Citadel: fast-path isConnected,
    /// then a bounded active round-trip — isConnected stays true on half-open TCP
    /// (NAT/firewall drops the mapping with no FIN/RST), so only traffic proves life.
    func probeLiveness() async -> Bool {
        // Skip probe while connecting to avoid wake misjudge
        if case .connecting = connectionState {
            return true
        }
        // Skip probe on pending auth failure to avoid stale retry
        if let typedFailure = pendingFailure, typedFailure.isAuthentication {
            return true
        }
        // Grace 10s after connect to avoid probe storm
        if let last = lastSuccessfulConnectionAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 10 {
                return true
            } else {}
        } else {}
        if usesOpenSSHTransport {
            guard let backend = openSSHBackend else {
                Log.ssh.warning("[PROBE] openssh no backend -> dead")
                return false
            }
            let transportAlive = await backend.checkControlMasterLiveness()
            guard transportAlive else {
                Log.ssh.warning("[PROBE] openssh transport dead")
                return false
            }
            // Transport alive -> validate Session/PTY (hard constraint 1)
            if let pty = activePTYSession {
                let closed = pty.isClosed
                if closed {
                    Log.ssh.warning("[PROBE] openssh transport alive but PTY closed")
                }
                return !closed
            }
            return true // no PTY yet, transport alive is enough
        } else {
            guard let client else {
                Log.ssh.warning("[PROBE] citadel no client -> dead")
                return false
            }
            // Fast-path negative only: a dead flag means dead, but a live flag
            // proves nothing on half-open TCP — follow with a round-trip.
            guard client.isConnected else {
                Log.ssh.warning("[PROBE] citadel transport disconnected")
                return false
            }
            guard await citadelRoundTrip(client) else {
                Log.ssh.warning("[PROBE] citadel transport silent (half-open?)")
                return false
            }
            if let pty = activePTYSession {
                let closed = pty.isClosed
                if closed {
                    Log.ssh.warning("[PROBE] citadel transport alive but PTY closed")
                }
                return !closed
            }
            return true
        }
    }

    /// Bounded active round-trip on the native transport — the only detector
    /// for half-open TCP. `executeCommand("true")` returns no output; the
    /// internal timeout converts silence to `false`. Callers add their own
    /// timeouts on top; this never blocks longer than `timeout`.
    private func citadelRoundTrip(_ client: SSHClient, timeout: Duration = .seconds(3)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await client.executeCommand("true")
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Timeout Helper

/// A simple timeout wrapper for async operations.
func withThrowingTimeout<T: Sendable>(
    of duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            return nil
        }
        defer { group.cancelAll() }
        if let result = try await group.next()! {
            return result
        }
        throw SSHTimeoutError()
    }
}

struct SSHTimeoutError: Error, LocalizedError {
    var errorDescription: String? {
        "Operation timed out"
    }
}
