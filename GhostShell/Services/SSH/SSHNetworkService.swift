//
//  SSHNetworkService.swift
//  GhostShell
//
//  Created by Joy Liam on 2026/5/25.
//

import Foundation
import Crypto
import NIOCore
import NIOConcurrencyHelpers
import os.log
@preconcurrency import NIOSSH
@preconcurrency import Citadel

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

    private var client: SSHClient?
    private var config: SSHConnectionConfig?
    private var activePTYSession: PTYSession?
    private var reconnectTask: Task<Void, Never>?
    private let keepAlive = SSHKeepAlive()

    /// Stores PTY parameters for reconnection.
    private struct PTYConfig: Sendable {
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

    public func connect(config: SSHConnectionConfig) async throws {
        guard !connectionState.isConnected else {
            throw SSHServiceError.alreadyConnected
        }

        self.config = config
        connectionState = .connecting
        stateContinuation.yield(.connecting)

        do {
            try await establishConnection(config: config)
            await keepAlive.start(client: client!)
        } catch {
            self.client = nil
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)

            if config.maxReconnectAttempts > 0 {
                try await reconnect()
            } else {
                throw SSHServiceError.connectionFailed(String(describing: error))
            }
        }
    }

    /// Shared SSH connection logic used by both connect() and reconnect().
    private func establishConnection(config: SSHConnectionConfig) async throws {
        let citadelAuth = try mapAuthMethod(config.authMethod, username: config.username)
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

        let sshClient = try await SSHClient.connect(
            host: config.host,
            port: Int(config.port),
            authenticationMethod: citadelAuth,
            hostKeyValidator: .custom(validator),
            reconnect: .never
        )

        try await verifyHostKey(
            host: config.host,
            port: config.port,
            fingerprint: fingerprintBox.withLockedValue { $0 },
            store: hostKeyStore
        )

        self.client = sshClient
        connectionState = .connected
        stateContinuation.yield(.connected)
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

    // MARK: - Reconnection State Machine

    private func reconnect() async throws {
        guard let config else { return }

        let maxAttempts = config.maxReconnectAttempts
        var attempt = 0

        while attempt < maxAttempts && !Task.isCancelled {
            connectionState = .reconnecting(attempt: attempt + 1, maxAttempts: maxAttempts)
            stateContinuation.yield(.reconnecting(attempt: attempt + 1, maxAttempts: maxAttempts))

            let baseSeconds = max(config.baseReconnectDelay.components.seconds, 1)
            let delaySeconds = min(baseSeconds * Int64(1 << min(attempt, 4)), 30)
            let jitterMs = Int64.random(in: 0..<500)
            let totalMs = delaySeconds * 1000 + jitterMs

            try? await Task.sleep(for: .milliseconds(Double(totalMs)))
            guard !Task.isCancelled else { break }

            do {
                try await establishConnection(config: config)

                if let ptyConfig = lastPTYConfig {
                    let session = PTYSession()
                    session.start(client: client!, cols: ptyConfig.cols, rows: ptyConfig.rows, termType: ptyConfig.termType)
                    activePTYSession = session
                    pendingPTYSession = session
                }
                return
            } catch {
                attempt += 1
            }
        }

        connectionState = .disconnected
        stateContinuation.yield(.disconnected)
        throw SSHServiceError.reconnectExhausted(attempts: maxAttempts)
    }

    // MARK: - Disconnect Monitor

    private func startMonitoringDisconnect(_ sshClient: SSHClient) {
        sshClient.onDisconnect { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect() }
        }
    }

    private func handleDisconnect() async {
        guard let config else { return }

        activePTYSession?.close()
        activePTYSession = nil
        client = nil

        guard config.maxReconnectAttempts > 0 else {
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)
            return
        }

        do {
            try await reconnect()
        } catch {
            Log.ssh.error("Reconnect failed: \(error.localizedDescription)")
            connectionState = .disconnected
            stateContinuation.yield(.disconnected)
        }
    }

    // MARK: - Host Key Verification (TOFU)

    private func verifyHostKey(
        host: String,
        port: UInt16,
        fingerprint: SSHHostFingerprint?,
        store: any SSHHostKeyStore
    ) async throws {
        guard let fingerprint else {
            Log.ssh.warning("No fingerprint computed for \(host):\(port)")
            return
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
        case .password(let pw):
            return .passwordBased(username: username, password: pw)

        case .privateKey(let pem):
            let raw = try decodePEM(pem)

            if let ed = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: username, privateKey: ed)
            }

            throw SSHServiceError.connectionFailed(
                "Unsupported key type. Only Ed25519 private keys are supported. Detected key is not Ed25519 (raw \(raw.count) bytes)."
            )
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

// MARK: - Host Key Validator

private nonisolated final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let onHostKey: @Sendable (NIOSSHPublicKey) -> Void

    init(onHostKey: @escaping @Sendable (NIOSSHPublicKey) -> Void) {
        self.onHostKey = onHostKey
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        onHostKey(hostKey)
        validationCompletePromise.succeed(())
    }
}
