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
    private var config: SSHConnectionConfig?
    private var activePTYSession: PTYSession?
    private let keepAlive = SSHKeepAlive()
    /// Guard against duplicate handleDisconnect calls (keepalive timeout + onDisconnect).
    private var isHandlingDisconnect = false
    /// Current reconnection loop, so manual disconnect/reconnect can cancel it.
    private var reconnectTask: Task<Void, Never>?

    /// Network monitor for detecting connectivity changes.
    private let networkMonitor = NWPathMonitor()
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

    /// PTY session created after reconnect — SessionManager consumes this.
    public private(set) var pendingPTYSession: PTYSession?

    private let hostKeyStore: any SSHHostKeyStore

    public init(hostKeyStore: some SSHHostKeyStore) {
        self.hostKeyStore = hostKeyStore
        var cont: AsyncStream<SSHConnectionState>.Continuation!
        (stateStream, cont) = AsyncStream<SSHConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateContinuation = cont
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
        config = SSHConnectionConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            maxReconnectAttempts: attempts,
            baseReconnectDelay: config.baseReconnectDelay
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
        connectionState = .connecting
        stateContinuation.yield(.connecting)
        Log.ssh.info("[CONNECT] State set to .connecting")

        do {
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
            await keepAlive.settimeoutHandler { [weak self] in
                guard let self else { return }
                Task { await self.handleDisconnect() }
            }
            await keepAlive.start(client: client)
            Log.ssh.info("[CONNECT] keepAlive started, connection complete")
        } catch {
            Log.ssh.error("[CONNECT] Connection failed: \(error.localizedDescription)")
            client = nil
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
        // RFC 8332 host-key algorithms (rsa-sha2-256/512) for bastions with
        // RSA host keys. Idempotent; safe to call on every connection.
        RSASHA2Support.register()
        var algorithms = SSHAlgorithms.all
        algorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroupExchangeSha256.self,
            DiffieHellmanGroupExchangeSha1.self,
            DiffieHellmanFixedGroup<DiffieHellmanGroup1SHA1Parameters>.self,
            DiffieHellmanFixedGroup<DiffieHellmanGroup16SHA512Parameters>.self,
            DiffieHellmanFixedGroup<DiffieHellmanGroup18SHA512Parameters>.self,
        ])
        algorithms.transportProtectionSchemes = .add([
            AES192CTRTransportProtection.self,
            AES256CTRTransportProtection.self,
        ])
        let sshClient = try await SSHClient.connect(
            host: config.host,
            port: Int(config.port),
            authenticationMethod: citadelAuth,
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            // Citadel's default algorithm set is empty (only swift-nio-ssh
            // bundled KEX: curve25519/ecdh). Bastions often only offer
            // diffie-hellman-group14-sha1/sha256 and RSA host keys, which
            // Citadel ships but doesn't enable by default.
            algorithms: algorithms
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

        client = sshClient
        connectionState = .connected
        stateContinuation.yield(.connected)
        Log.ssh.info("[ESTABLISH] State set to .connected, starting disconnect monitor")
        startMonitoringDisconnect(sshClient)
    }

    // MARK: - Exec

    /// Execute a command via a separate SSH exec channel (no PTY).
    /// Returns clean stdout with no ANSI codes, no prompt, no echo.
    public func executeCommand(_ command: String) async throws -> String {
        guard let client else { throw SSHServiceError.notConnected }
        let response = try await client.executeCommand(command)
        return String(buffer: response).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SFTP

    /// Open an SFTP client over the existing SSH connection.
    public func openSFTPClient() async throws -> SFTPClient {
        guard let client else { throw SSHServiceError.notConnected }
        return try await client.openSFTP()
    }

    // MARK: - PTY

    public func openPTY(
        cols: Int = 80,
        rows: Int = 24,
        termType: String = "xterm-256color"
    ) async throws -> PTYSession {
        guard let client else { throw SSHServiceError.notConnected }

        lastPTYConfig = PTYConfig(cols: cols, rows: rows, termType: termType)
        let session = PTYSession()
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

    public func disconnect() async {
        await keepAlive.stop()

        stopNetworkMonitor()
        reconnectTask?.cancel()
        reconnectTask = nil

        activePTYSession?.close()
        activePTYSession = nil

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

        let queue = DispatchQueue(label: "com.bonk.ssh.network-monitor")
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task {
                await self?.handleNetworkChange(path)
            }
        }
        networkMonitor.start(queue: queue)
    }

    /// Stop monitoring network connectivity.
    private func stopNetworkMonitor() {
        networkMonitor.cancel()
        isMonitoringNetwork = false
        isWaitingForNetwork = false
    }

    /// Handle network connectivity changes.
    private func handleNetworkChange(_ path: NWPath) async {
        // Only act if we're in a disconnected/reconnecting state and waiting for network
        guard isWaitingForNetwork, path.status == .satisfied else { return }

        Log.ssh.info("[NETWORK] Network restored, attempting reconnection...")
        isWaitingForNetwork = false

        // Network is back — attempt immediate reconnection
        guard config != nil else { return }
        startReconnect()
    }

    // MARK: - Reconnection State Machine

    private func startReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { await self.reconnect() }
    }

    private func reconnect() async {
        guard let config else { return }

        let maxAttempts = max(config.maxReconnectAttempts, 1)
        var attempt = 0

        // Bounded retries with exponential backoff (capped at 30s), then give
        // up and let the user reconnect manually. Retrying forever is what
        // produced hundreds of reconnect attempts against an unreachable host.
        while attempt < maxAttempts, !Task.isCancelled {
            connectionState = .reconnecting(attempt: attempt + 1, maxAttempts: maxAttempts)
            stateContinuation.yield(.reconnecting(attempt: attempt + 1, maxAttempts: maxAttempts))

            let baseSeconds = max(config.baseReconnectDelay.components.seconds, 1)
            let delaySeconds = min(baseSeconds * Int64(1 << min(attempt, 4)), 30)
            let jitterMs = Int64.random(in: 0 ..< 500)
            let totalMs = delaySeconds * 1000 + jitterMs

            try? await Task.sleep(for: .milliseconds(Double(totalMs)))
            guard !Task.isCancelled else { break }

            do {
                try await establishConnection(config: config)

                // Reconnection successful — stop network monitor if active
                stopNetworkMonitor()

                if let ptyConfig = lastPTYConfig, let client {
                    let session = PTYSession()
                    session.start(
                        client: client, cols: ptyConfig.cols,
                        rows: ptyConfig.rows, termType: ptyConfig.termType
                    )
                    activePTYSession = session
                    pendingPTYSession = session
                }
                return
            } catch is CancellationError {
                break
            } catch let error as SSHServiceError {
                // Fatal errors: don't retry
                switch error {
                case .hostKeyMismatch, .alreadyConnected:
                    Log.ssh.error("Fatal SSH error, aborting reconnect: \(error.localizedDescription)")
                    return
                case .notConnected, .connectionFailed, .reconnectExhausted:
                    Log.ssh.warning(
                        "Recoverable SSH error (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)"
                    )
                    attempt += 1
                }
            } catch is SSHTimeoutError {
                Log.ssh.warning("Reconnect attempt \(attempt + 1)/\(maxAttempts) timed out")
                attempt += 1
            } catch {
                // Generic errors (network timeouts, DNS failures, etc.) — retry
                Log.ssh.warning(
                    "Reconnect attempt \(attempt + 1)/\(maxAttempts) failed: \(error.localizedDescription)"
                )
                attempt += 1
            }
        }

        if !Task.isCancelled {
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)
            Log.ssh.error("Reconnect exhausted after \(maxAttempts) attempts")
        }
    }

    // MARK: - Disconnect Monitor

    private func startMonitoringDisconnect(_ sshClient: SSHClient) {
        sshClient.onDisconnect { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect() }
        }
    }

    private func handleDisconnect() async {
        // Guard against duplicate calls (keepalive timeout + onDisconnect may fire close together).
        guard !isHandlingDisconnect else { return }
        isHandlingDisconnect = true
        defer { isHandlingDisconnect = false }

        guard let config else { return }

        activePTYSession?.close()
        activePTYSession = nil
        client = nil

        guard config.maxReconnectAttempts > 0 else {
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)
            return
        }

        startReconnect()
    }

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

        case let .certificate(privateKeyPEM, certificatePEM):
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
