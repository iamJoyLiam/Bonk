//
//  SSHNetworkService+ReconnectAttempt.swift
//  Bonk
//
//  Single-attempt reconnect extracted from SSHNetworkService to keep the actor
//  body within size limits. Same-module extension: only internal members are used.
//

@preconcurrency import Citadel
import Crypto
import Foundation
import Network
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import os.log

// MARK: - SSHNetworkService Reconnect Attempt

extension SSHNetworkService {
    /// Single reconnect attempt - supervisor handles backoff loop.
    /// MUST recreate PTY on success (spec: dead -> reconnect -> SSH auth -> open channel -> recreate PTY -> restore size -> reattach -> ready)
    func performSingleReconnect() async -> Bool {
        guard let config else { return false }
        let newAttemptID = UUID()
        currentAttemptID = newAttemptID
        Log.ssh.info("[RECOVERY] new attemptID=\(newAttemptID.uuidString.prefix(8), privacy: .public) host=\(config.host, privacy: .public)")
        // Fix 2: keep old PTY/client until new is confirmed (make-before-break)
        let oldPTY = activePTYSession
        let oldClient = client
        let oldBackend = openSSHBackend
        await keepAlive.stop()
        // Do not clear activePTYSession yet — keep old usable until new is ready
        // Single attempt (no loop) - supervisor will retry with backoff
        // 4-stage success: process/TCP -> auth -> PTY -> session
        do {
            if usesOpenSSHTransport {
                try? await Task.sleep(for: .milliseconds(1))
                // Diag: password fingerprint
                let cfgDesc = switch config.authMethod {
                case let .password(password): "password(len=\(password.count) fp=\(OpenSSHBackend.passwordFingerprint(password)))"
                case let .privateKey(privateKeyString): "privateKey(len=\(privateKeyString.count))"
                case let .certificate(keyData, certificateData): "cert(k=\(keyData.count) c=\(certificateData.count))"
                case let .secureEnclaveKey(tag): "sece(\(tag))"
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
                        // Extreme: minimal window for delayed Permission denied (50ms total)
                        for _ in 0 ..< 5 {
                            if let typedFailure = self.pendingFailure, typedFailure.isAuthentication { break }
                            if session.isClosed { break }
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        if let typedFailure = self.pendingFailure, typedFailure.isAuthentication {
                            Log.ssh.warning("[RECOVERY_STEP] authenticationSucceeded=false reason=\(typedFailure.message.prefix(80), privacy: .public)")
                            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed (reconnect)")
                            await self.suppressRecoveryForAuth()
                            session.close()
                            authSucceeded = false
                        } else if await !session.waitForChannelReady() {
                            Log.ssh.warning("[RECOVERY_STEP] ptyReady=false")
                            authSucceeded = false
                        } else {
                            session.onWriteFailed = { [weak self] in
                                guard let self, self.attemptIDBox.withLockedValue({ $0 }) == capturedID else { return }
                                Task { await self.handlePTYWriteFailed() }
                            }
                            ptySession = session
                            activePTYSession = session
                            pendingPTYSession = session
                            Log.ssh.info("[RECOVERY_STEP] ptyReady=true outputBound=true (pendingPTY set)")
                            // Fix 2: close old only after new is confirmed (make-before-break)
                            oldPTY?.close()
                            // oldBackend kept as openSSHBackend now, oldClient not used for openssh
                        }
                    } catch {
                        Log.ssh.warning("[RECOVERY] OpenSSH PTY recreate failed: \(error.localizedDescription, privacy: .public)")
                        Log.ssh.warning("[RECOVERY_STEP] ptyReady=false outputBound=false")
                        return false
                    }
                    if lastPTYConfig != nil {
                        guard authSucceeded, ptySession != nil else {
                            Log.ssh.warning("[RECOVERY_STEP] outputBound=false authSucceeded=\(authSucceeded, privacy: .public)")
                            return false
                        }
                    } else {
                        guard authSucceeded else {
                            Log.ssh.warning("[RECOVERY_STEP] authenticationSucceeded=false")
                            return false
                        }
                    }
                    Log.ssh.info("[RECOVERY_STEP] transportReady=true authenticationSucceeded=\(authSucceeded, privacy: .public)")
                } else {
                    Log.ssh.info("[RECOVERY_STEP] transportReady=true (no PTY)")
                }
                markReconnected()
                Log.ssh.info("[RECOVERY] OpenSSH reconnect success (transport/pty/output all ready)")
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
                        Task { await self.handlePTYWriteFailed() }
                    }
                    session.start(client: client, cols: ptyConfig.cols, rows: ptyConfig.rows, termType: ptyConfig.termType)
                    // start() opens the channel asynchronously — wait instead of
                    // reading stale pre-open state (isClosed would always be true).
                    let ptyReady = await session.waitForChannelReady()
                    guard ptyReady else {
                        Log.ssh.warning("[RECOVERY_STEP] ptyReady=false")
                        return false
                    }
                    activePTYSession = session
                    pendingPTYSession = session
                    Log.ssh.info("[RECOVERY_STEP] ptyReady=true outputBound=true (pendingPTY set)")
                    // Fix 2: close old after new is ready
                    oldPTY?.close()
                    try? await oldClient?.close()
                } else {
                    Log.ssh.info("[RECOVERY_STEP] transportReady=true (no PTY)")
                }
                Log.ssh.info("[RECOVERY_STEP] transportReady=true ptyReady=\(self.lastPTYConfig != nil ? "true" : "no PTY", privacy: .public)")
                // Publish .connected so the observer consumes pendingPTY and
                // rebinds pane + output stream (same as the OpenSSH branch).
                markReconnected()
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

    /// Shared tail of a successful reconnect attempt: publish .connected so
    /// the observer consumes pendingPTY and rebinds pane + output stream.
    func markReconnected() {
        connectionState = .connected
        stateContinuation.yield(.connected)
        lastSuccessfulConnectionAt = Date()
    }
}
