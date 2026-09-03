//
//  SSHNetworkService.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

@preconcurrency import Citadel
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Network
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
    public private(set) var connectionState: SSHConnectionState = .disconnected

    /// State stream for external observation (SessionManager subscribes to this).
    public let stateStream: AsyncStream<SSHConnectionState>
    private let stateContinuation: AsyncStream<SSHConnectionState>.Continuation

    /// Expose client for port forwarding. Returns nil if not connected.
    public var sshClient: SSHClient? {
        client
    }

    private var client: SSHClient?
    /// Separate native Citadel connection used only by legacy SFTP flow when
    /// the terminal transport is system OpenSSH.
    private var sftpNativeClient: SSHClient?
    private var config: SSHConnectionConfig?
    private var activePTYSession: PTYSession?
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
        private var openSSHBackend: OpenSSHBackend?
    #endif
    private var usesOpenSSHTransport = false
    private let keepAlive = SSHKeepAlive()
    /// Per-session supervisor - replaces isHandlingDisconnect Bool with state machine per P0 spec.
    private let supervisor = SSHConnectionSupervisor()
    private var wakeMonitorTask: Task<Void, Never>?
    /// ConnectionAttemptID per hard constraint 3 - old callbacks with stale ID are discarded
    private let attemptIDBox = NIOLockedValueBox<UUID>(UUID())
    private var currentAttemptID: UUID {
        get { attemptIDBox.withLockedValue { $0 } }
        set { attemptIDBox.withLockedValue { $0 = newValue } }
    }
    /// Current reconnection loop, so manual disconnect/reconnect can cancel it.
    private var reconnectTask: Task<Void, Never>?

    /// Network monitor for detecting connectivity changes.
    private var networkMonitor: NWPathMonitor?
    private var isMonitoringNetwork = false
    /// Whether we're waiting for network to come back (for delayed reconnect).
    private var isWaitingForNetwork = false

    /// Stores PTY parameters for reconnection.
    private struct PTYConfig {
        let cols: Int
        let rows: Int
        let termType: String
    }

    private var lastPTYConfig: PTYConfig?
    private var lastSuccessfulConnectionAt: Date?
    /// Last typed failure for gate & debug — set by handleTypedFailure
    private var pendingFailure: SSHFailure?
    /// Callback for SessionManager to present AuthRetrySheet on typed auth failure (including reconnect PTYs)
    private var onAuthFailureHandler: (@Sendable (SSHFailure) -> Void)?

    /// PTY session created after reconnect — SessionManager consumes this.
    public private(set) var pendingPTYSession: PTYSession?

    private let hostKeyStore: any SSHHostKeyStore
    // VNext — forced backend for Hybrid routing (T2.2). When set, overrides shouldUseOpenSSH.
    private var vnextForcedBackend: SSHBackendType?

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
    private static let connectionTimeoutSeconds: Int = 10

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
    private func establishConnection(config: SSHConnectionConfig) async throws {
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
    public func executeCommand(_ command: String) async throws -> String {
        guard case .connected = connectionState else {
            throw SSHServiceError.notConnected
        }
        #if os(macOS)
            if usesOpenSSHTransport, let openSSHBackend {
                // Commands normally finish in seconds; a half-open connection
                // would hang this forever, so bound it.
                return try await withThrowingTimeout(of: .seconds(30)) {
                    try await openSSHBackend.executeCommand(command)
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
                    Task { await self.supervisor.requestRecovery(reason: .writeFailed) }
                }
                return session
            }
        #endif

        guard let client else { throw SSHServiceError.notConnected }

        lastPTYConfig = PTYConfig(cols: cols, rows: rows, termType: termType)
        let session = PTYSession()
        session.generation = capturedAttemptID
        session.onWriteFailed = { [weak self] in
            guard let self, self.attemptIDBox.withLockedValue { $0 } == capturedAttemptID else { return }
            Task { await self.supervisor.requestRecovery(reason: .writeFailed) }
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

    /// Set handler for typed auth failures — SessionManager presents AuthRetrySheet (also for reconnect PTYs)
    public func setAuthFailureHandler(_ handler: (@Sendable (SSHFailure) -> Void)?) {
        onAuthFailureHandler = handler
    }

    /// Auth failure gate — cancel any recovery and forbid supervisor auto-retry until next connect.
    public func suppressRecoveryForAuth() async {
        await supervisor.suppressRecoveryForAuth()
    }

    /// Typed failure handler — central Recovery gate logging
    private func handleTypedFailure(_ failure: SSHFailure) async {
        switch failure {
        case .authentication(let authFailure):
            Log.ssh.info("[SSH_FAILURE] type=authentication backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public) detail=\(authFailure.message.prefix(120), privacy: .public)")
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed")
            await self.suppressRecoveryForAuth()
            self.pendingFailure = failure
            self.stopWakeMonitoring()
            // SessionManager  sheet reconnect PTY
            if let handler = self.onAuthFailureHandler { handler(failure) }
        case .hostKey(let hostKeyMessage):
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
        case .transport(let transportFailure):
            Log.ssh.info("[SSH_FAILURE] type=transport backend=\(self.usesOpenSSHTransport ? "openssh" : "citadel", privacy: .public) detail=\(transportFailure.message.prefix(120), privacy: .public)")
            Log.ssh.info("[RECOVERY_GATE] blocked=false reason=transportFailed")
            self.pendingFailure = failure
        case .unknown(let unknownMessage):
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

    // MARK: - Network Monitoring

    /// Start monitoring network connectivity changes.
    private func startNetworkMonitor() {
        guard !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        // A cancelled NWPathMonitor cannot be restarted — always build a
        // fresh instance (stopNetworkMonitor() cancels the previous one).
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        let queue = DispatchQueue(label: "com.bonk.ssh.network-monitor")
        monitor.pathUpdateHandler = { [weak self] path in
            Task {
                await self?.handleNetworkChange(path)
            }
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring network connectivity.
    private func stopNetworkMonitor() {
        networkMonitor?.cancel()
        networkMonitor = nil
        isMonitoringNetwork = false
        isWaitingForNetwork = false
    }

    /// Handle network connectivity changes - funnel through supervisor per P0.
    private func handleNetworkChange(_ path: NWPath) async {
        guard path.status == .satisfied else { return }
        guard config != nil else { return }
        if case .connecting = connectionState {
            Log.ssh.info("[NETWORK] ignore networkChanged during connecting")
            return
        }
        // Skip if PTY not yet created to avoid tearing down new backend
        if usesOpenSSHTransport, activePTYSession == nil, lastPTYConfig == nil {
            Log.ssh.info("[NETWORK] ignore networkChanged - PTY not yet created (connect window)")
            return
        }
        if let typedFailure = pendingFailure, typedFailure.isAuthentication || typedFailure.typeString == "hostKey" || typedFailure.typeString == "cancelled" {
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=\(typedFailure.typeString, privacy: .public) handleNetworkChange suppressed")
            return
        }
        Log.ssh.info("[NETWORK] Network restored, probing liveness...")
        await supervisor.requestRecovery(reason: .networkChanged)
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
                    // OpenSSH path: re-create ControlMaster socket
                    try? await Task.sleep(for: .milliseconds(200))
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
    private func reconnectOpenSSH(config: SSHConnectionConfig) async {
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

    private func handleDisconnect() async {
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

    public func lastTypedFailure() -> SSHFailure? { pendingFailure }
    public func clearTypedFailure() { pendingFailure = nil; lastSuccessfulConnectionAt = nil }

    // MARK: - P0 Wake & Probe Integration

    private func configureSupervisorForCurrentConnection() {
        guard let config else { return }
        let hostLabel = "\(config.username)@\(config.host):\(config.port)"
        let engineLabel = usesOpenSSHTransport ? "openssh" : "citadel"
        Task {
            await supervisor.configure(
                host: hostLabel,
                engine: engineLabel,
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
                    // Probe alive -> no state change, remain ready; log for diagnostics
                    Log.ssh.info("[RECOVERY] probe alive keep ready host=\(hostLabel, privacy: .public)")
                    Task { await self.supervisor.reset() }
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
                case .systemWake(_, let duration):
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
    /// OpenSSH: check ControlMaster then validate PTY; Citadel: check isConnected then PTY.
    /// Never uses kill(pid,0) or exec true as health (spec).
    private func probeLiveness() async -> Bool {
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
            } else {
            }
        } else {
        }
        if usesOpenSSHTransport {
            guard let backend = openSSHBackend else {
                Log.ssh.warning("[PROBE] openssh no backend -> dead")
                return false
            }
            let transportAlive = await backend.checkControlMasterLiveness()
            guard transportAlive else { return false }
            // Transport alive -> validate Session/PTY (hard constraint 1)
            if let pty = activePTYSession {
                let ptyAlive = !pty.isClosed
                return ptyAlive
            }
            return true // no PTY yet, transport alive is enough
        } else {
            guard let client else {
                Log.ssh.warning("[PROBE] citadel no client -> dead")
                return false
            }
            let transportAlive = client.isConnected
            guard transportAlive else { return false }
            if let pty = activePTYSession {
                let ptyAlive = !pty.isClosed
                return ptyAlive
            }
            return true
        }
    }

    /// Single reconnect attempt - supervisor handles backoff loop.
    /// MUST recreate PTY on success (spec: dead -> reconnect -> SSH auth -> open channel -> recreate PTY -> restore size -> reattach -> ready)
    private func performSingleReconnect() async -> Bool {
        guard let config else { return false }
        let newAttemptID = UUID()
        currentAttemptID = newAttemptID
        Log.ssh.info("[RECOVERY] new attemptID=\(newAttemptID.uuidString.prefix(8), privacy: .public) host=\(config.host, privacy: .public)")
        // Tear down stale resources before new attempt
        await keepAlive.stop()
        activePTYSession?.close()
        activePTYSession = nil
        client = nil
        if usesOpenSSHTransport {
            openSSHBackend?.close()
            openSSHBackend = nil
        }
        // Single attempt (no loop) - supervisor will retry with backoff
        // 4-stage success: process/TCP -> auth -> PTY -> session
        do {
            if usesOpenSSHTransport {
                try? await Task.sleep(for: .milliseconds(200))
                // Diag: password fingerprint
                let cfgDesc: String
                switch config.authMethod {
                case .password(let password): cfgDesc = "password(len=\(password.count) fp=\(OpenSSHBackend.passwordFingerprint(password)))"
                case .privateKey(let privateKeyString): cfgDesc = "privateKey(len=\(privateKeyString.count))"
                case .certificate(let keyData, let certificateData): cfgDesc = "cert(k=\(keyData.count) c=\(certificateData.count))"
                case .secureEnclaveKey(let tag): cfgDesc = "sece(\(tag))"
                }
                let backend: OpenSSHBackend
                do {
                    // Ensure generation matches to avoid stale PTY tail
                    let genConfig = SSHConnectionConfig(
                        host: config.host, port: config.port, username: config.username,
                        authMethod: config.authMethod, jumpHost: config.jumpHost,
                        maxReconnectAttempts: config.maxReconnectAttempts, baseReconnectDelay: config.baseReconnectDelay,
                        algorithmRequirements: config.algorithmRequirements,
                        bypassControlMaster: config.bypassControlMaster,
                        generation: newAttemptID
                    )
                    backend = try OpenSSHBackend(config: genConfig)
                } catch {
                    Log.ssh.warning("[RECOVERY_STEP] transportConnected=false reason=\(error.localizedDescription, privacy: .public)")
                    return false
                }
                openSSHBackend = backend
                usesOpenSSHTransport = true
                pendingFailure = nil
                // authenticationSucceeded:  typed auth 300ms  PTY  auth
                // PTY  onFailure  pendingFailure
                var authSucceeded = true
                var ptySession: PTYSession?
                if let ptyConfig = lastPTYConfig {
                    do {
                        let capturedID = newAttemptID
                        let session = try backend.openPTY(
                            cols: ptyConfig.cols, rows: ptyConfig.rows, termType: ptyConfig.termType
                        ) { [weak self] in
                            guard let self, self.attemptIDBox.withLockedValue { $0 } == capturedID else {
                                Log.ssh.info("[RECOVERY] discard stale HUP old=\(capturedID.uuidString.prefix(8), privacy: .public)")
                                return
                            }
                            Task { await self.handleDisconnect() }
                        } onError: { _ in } onFailure: { [weak self] failure in
                            Task { await self?.handleTypedFailure(failure) }
                        }
                        // Longer window for delayed Permission denied
                        for _ in 0..<70 {
                            if let typedFailure = self.pendingFailure, typedFailure.isAuthentication { break }
                            if session.isClosed { break }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        if let typedFailure = self.pendingFailure, typedFailure.isAuthentication {
                            Log.ssh.warning("[RECOVERY_STEP] authenticationSucceeded=false reason=\(typedFailure.message.prefix(80), privacy: .public)")
                            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed (reconnect)")
                            await self.suppressRecoveryForAuth()
                            session.close()
                            authSucceeded = false
                        } else if session.isClosed {
                            Log.ssh.warning("[RECOVERY_STEP] ptyReady=false")
                            authSucceeded = false
                        } else {
                            session.onWriteFailed = { [weak self] in
                                guard let self, self.attemptIDBox.withLockedValue({ $0 }) == capturedID else { return }
                                Task { await self.supervisor.requestRecovery(reason: .writeFailed) }
                            }
                            ptySession = session
                            activePTYSession = session
                            pendingPTYSession = session
                        }
                    } catch {
                        Log.ssh.warning("[RECOVERY] OpenSSH PTY recreate failed: \(error.localizedDescription, privacy: .public)")
                        return false
                    }
                    // lastPTYConfig  ptySession ； openPTY transport+auth
                    if lastPTYConfig != nil {
                        guard authSucceeded, ptySession != nil else { return false }
                    } else {
                        guard authSucceeded else { return false }
                    }
                } else {
                }
                connectionState = .connected
                stateContinuation.yield(.connected)
                lastSuccessfulConnectionAt = Date()
                Log.ssh.info("[RECOVERY] OpenSSH reconnect success (4 stages)")
                await keepAlive.stop()
                startNetworkMonitor()
                return true
            } else {
                // transportConnected + authenticationSucceeded via establishConnection
                try await withThrowingTimeout(of: .seconds(Self.connectionTimeoutSeconds)) {
                    try await self.establishConnection(config: config)
                }
                if let client {
                    let capturedKeepAliveID = newAttemptID
                    await keepAlive.settimeoutHandler { [weak self] in
                        guard let self, self.attemptIDBox.withLockedValue { $0 } == capturedKeepAliveID else {
                            Log.ssh.info("[RECOVERY] discard stale keepAlive old=\(capturedKeepAliveID.uuidString.prefix(8), privacy: .public)")
                            return
                        }
                        Task { await self.supervisor.requestRecovery(reason: .keepAliveTimeout) }
                    }
                    await keepAlive.start(client: client)
                }
                // ptyReady + sessionReady
                if let ptyConfig = lastPTYConfig, let client {
                    let capturedID = newAttemptID
                    let session = PTYSession()
                    session.onWriteFailed = { [weak self] in
                        guard let self, self.attemptIDBox.withLockedValue { $0 } == capturedID else { return }
                        Task { await self.supervisor.requestRecovery(reason: .writeFailed) }
                    }
                    session.start(client: client, cols: ptyConfig.cols, rows: ptyConfig.rows, termType: ptyConfig.termType)
                    let ptyReady = !session.isClosed
                    guard ptyReady else { return false }
                    activePTYSession = session
                    pendingPTYSession = session
                } else {
                }
                startNetworkMonitor()
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            Log.ssh.warning("[RECOVERY] single reconnect failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    #if os(macOS)
        /// Start an OpenSSH-backed port forward for this connected target.
        func startPortForward(
            _ forward: SSHPortForwardConfiguration,
            onExit: @escaping @Sendable () -> Void
        ) async throws -> OpenSSHForwardHandle {
            guard usesOpenSSHTransport, let openSSHBackend else {
                throw SSHServiceError.connectionFailed(
                    "OpenSSH port forwarding requires an OpenSSH-backed connection."
                )
            }
            return try openSSHBackend.startPortForward(config: forward, onExit: onExit)
        }
    #endif

    // MARK: - Host Key Verification (TOFU)

    private func verifyHostKey(
        host: String,
        port: UInt16,
        fingerprint: SSHHostFingerprint?,
        store: any SSHHostKeyStore
    ) async throws {
        guard let fingerprint else {
            Log.ssh.error("No fingerprint computed for \(host):\(port), refusing connection")
            throw SSHServiceError.hostKeyMismatch(expected: "unknown", received: "none")
        }

        Log.ssh.info("Fingerprint for \(host):\(port): \(fingerprint.hash)")

        if let known = await store.knownFingerprint(for: host, port: port) {
            Log.ssh.info("Known fingerprint: \(known.hash)")
            guard known.hash == fingerprint.hash else {
                throw SSHServiceError.hostKeyMismatch(
                    expected: known.hash,
                    received: fingerprint.hash
                )
            }
        } else {
            Log.ssh.info("First connection, saving fingerprint")
            await store.saveFingerprint(fingerprint, for: host, port: port)
        }
    }

    // MARK: - Auth Mapping

    private func mapAuthMethod(
        _ method: SSHAuthMethod,
        username: String
    ) throws -> SSHAuthenticationMethod {
        switch method {
        case let .password(password):
            return .passwordBased(username: username, password: password)

        case let .privateKey(pem):
            let raw = try decodePEM(pem)

            if let edKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: username, privateKey: edKey)
            }

            throw SSHServiceError.connectionFailed(
                "Unsupported key type. Only Ed25519 private keys are supported. "
                    + "Detected key is not Ed25519 (raw \(raw.count) bytes)."
            )

        case let .certificate(privateKeyPEM, _):
            let raw = try decodePEM(privateKeyPEM)

            if let edKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                Log.ssh.info("Using certificate authentication for \(username)")
                return .ed25519(username: username, privateKey: edKey)
            }

            throw SSHServiceError.connectionFailed(
                "Certificate authentication requires an Ed25519 private key."
            )

        case let .secureEnclaveKey(keyTag):
            // Secure Enclave authentication: use custom NIOSSH key provider
            Log.ssh.info("Using Secure Enclave key for \(username)")
            let secureEnclaveKey = try SecureEnclaveKeyManager.getPrivateKey(tag: keyTag)
            return .custom(SecureEnclaveAuthDelegate(
                username: username,
                privateKey: secureEnclaveKey
            ))
        }
    }

    #if os(macOS)
        private func shouldUseOpenSSH(_ method: SSHAuthMethod) -> Bool {
            if let forced = vnextForcedBackend {
                return forced == .compatibility
            }
            switch method {
            case .secureEnclaveKey:
                return false
            case .password, .privateKey, .certificate:
                return true
            }
        }

        /// VNext: force next connect to use a specific backend (T2.2).
        public func setVNextPreferredBackend(_ backend: SSHBackendType?) {
            vnextForcedBackend = backend
        }

        /// VNext T5 — vend a unified session for SFTP multiplexing on the same connection.
        public func makeVNextSession(endpoint: SSHEndpoint) -> (any SSHSession)? {
            #if os(macOS)
            if usesOpenSSHTransport, let backend = openSSHBackend {
                return CompatibilitySSHSession(backend: backend, endpoint: endpoint)
            }
            #endif
            if let activeClient = client {
                if let cfg = config {
                    return NativeSSHSession(client: activeClient, endpoint: endpoint, config: cfg, hostKeyStore: hostKeyStore)
                }
                return NativeSSHSession(client: activeClient, endpoint: endpoint)
            }
            return nil
        }
    #endif

    private nonisolated func decodePEM(_ pem: String) throws -> Data {
        let base64 = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()

        guard let data = Data(base64Encoded: base64) else {
            throw SSHServiceError.connectionFailed("Invalid base64 in PEM key")
        }
        return data
    }
}

// MARK: - Timeout Helper

/// A simple timeout wrapper for async operations.
private func withThrowingTimeout<T: Sendable>(
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

private struct SSHTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "Operation timed out" }
}
