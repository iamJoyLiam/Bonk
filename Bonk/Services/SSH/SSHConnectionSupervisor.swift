// SSHConnectionSupervisor.swift
// Bonk
//
// Per-session isolated recovery state machine per P0 spec.
// - per-session isolation (one zombie affects only its session)
// - requestRecovery(reason:) idempotent (concurrent triggers => 1 pipeline)
// - async, never blocks MainActor / NIO EventLoop
// - recovery success MUST recreate PTY (not fake .ready)

import Foundation
import os.log

/// Reason for recovery - diagnostics and de-duplication.
public enum RecoveryReason: Sendable, Equatable, CustomStringConvertible {
    case channelClosed
    case keepAliveTimeout
    case wakeProbeFailed(sleepDuration: TimeInterval?)
    case networkChanged
    case writeFailed
    case readTimeout
    case userRequested
    case authFailed // explicit auth failure — must NOT trigger recovery

    public var description: String {
        switch self {
        case .channelClosed: return "channelClosed"
        case .keepAliveTimeout: return "keepAliveTimeout"
        case .wakeProbeFailed(let duration):
            if let duration { return "wakeProbeFailed(sleep:\(Int(duration))s)" }
            return "wakeProbeFailed"
        case .networkChanged: return "networkChanged"
        case .writeFailed: return "writeFailed"
        case .readTimeout: return "readTimeout"
        case .userRequested: return "userRequested"
        case .authFailed: return "authFailed"
        }
    }
}

/// Recovery state machine - replaces isHandlingDisconnect Bool.
public enum RecoveryState: Sendable, Equatable, CustomStringConvertible {
    case idle
    case probing
    case reconnecting(attempt: Int)
    case backoff(delay: Duration)

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .probing: return "probing"
        case .reconnecting(let attempt): return "reconnecting(\(attempt))"
        case .backoff(let delay): return "backoff(\(delay))"
        }
    }
}

/// Per-session supervisor. One instance per SSHNetworkService (per tab).
/// All recovery triggers funnel through requestRecovery(reason:).
actor SSHConnectionSupervisor {
    private var state: RecoveryState = .idle
    private var currentTask: Task<Void, Never>?
    private var attemptCount: Int = 0
    private var suppressRecoveryUntil: Date? = nil // authFailed gate

    // Injected dependencies - set by owning SSHNetworkService
    private var probe: (@Sendable () async -> Bool)?
    private var reconnect: (@Sendable () async -> Bool)?
    private var onProbedAlive: (@Sendable () -> Void)?
    private var onReconnecting: (@Sendable (_ attempt: Int, _ maxAttempts: Int) -> Void)?
    private var onExhausted: (@Sendable () -> Void)?
    private var hostIdentifier: String = "unknown"
    private var engineName: String = "unknown"
    private var maxAttempts: Int = 7

    /// Configure supervisor with probe/reconnect closures and lifecycle callbacks. Called once per connection.
    func configure(
        host: String,
        engine: String,
        maxAttempts: Int = 7,
        probe: @escaping @Sendable () async -> Bool,
        reconnect: @escaping @Sendable () async -> Bool,
        onProbedAlive: @escaping @Sendable () -> Void,
        onReconnecting: (@Sendable (_ attempt: Int, _ maxAttempts: Int) -> Void)? = nil,
        onExhausted: (@Sendable () -> Void)? = nil
    ) {
        self.hostIdentifier = host
        self.engineName = engine
        self.maxAttempts = max(1, maxAttempts)
        self.probe = probe
        self.reconnect = reconnect
        self.onProbedAlive = onProbedAlive
        self.onReconnecting = onReconnecting
        self.onExhausted = onExhausted
        // Reset state on new connection
        state = .idle
        attemptCount = 0
        currentTask?.cancel()
        currentTask = nil
    }

    func reset() {
        state = .idle
        attemptCount = 0
        currentTask?.cancel()
        currentTask = nil
        suppressRecoveryUntil = nil
    }

    /// Auth failure gate — suppress any RECOVERY for this session until next user-initiated connect.
    func suppressRecoveryForAuth() {
        Log.ssh.info("[RECOVERY] suppress for authFailed host=\(self.hostIdentifier, privacy: .public)")
        state = .idle
        currentTask?.cancel()
        currentTask = nil
        attemptCount = 0
        // Suppress for 60s or until next configure/reset (which clears it)
        suppressRecoveryUntil = Date().addingTimeInterval(60)
    }

    /// Idempotent recovery entry - all triggers funnel here.
    /// Concurrent calls while probing/reconnecting/backoff are ignored (1 pipeline),
    /// except userRequested which preempts for immediate retry.
    func requestRecovery(reason: RecoveryReason) {
        // Manual reconnect should preempt any ongoing backoff/probing (fixes 202 requiring close tab)
        if reason == .userRequested, state != .idle {
            Log.ssh.info("[RECOVERY] preempt host=\(self.hostIdentifier, privacy: .public) reason=\(String(describing: reason), privacy: .public) state=\(String(describing: self.state), privacy: .public) engine=\(self.engineName, privacy: .public)")
            state = .idle
            currentTask?.cancel()
            currentTask = nil
            attemptCount = 0
        }
        // AuthFailed/hostKey/cancelled gate — never recover automatically
        if let until = suppressRecoveryUntil, Date() < until {
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed host=\(self.hostIdentifier, privacy: .public) reasonDetail=\(String(describing: reason), privacy: .public) state=\(String(describing: self.state), privacy: .public) engine=\(self.engineName, privacy: .public)")
            Log.ssh.info("[RECOVERY] suppressed host=\(self.hostIdentifier, privacy: .public) reason=\(String(describing: reason), privacy: .public) state=\(String(describing: self.state), privacy: .public) engine=\(self.engineName, privacy: .public) (authFailed gate)")
            return
        }
        if case .authFailed = reason {
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed host=\(self.hostIdentifier, privacy: .public)")
            Log.ssh.info("[RECOVERY] ignore authFailed host=\(self.hostIdentifier, privacy: .public) (sheet, not recovery)")
            return
        }
        // Idempotent: only idle can start new pipeline
        guard case .idle = state else {
            Log.ssh.info("[RECOVERY] ignore duplicate host=\(self.hostIdentifier, privacy: .public) reason=\(String(describing: reason), privacy: .public) state=\(String(describing: self.state), privacy: .public) engine=\(self.engineName, privacy: .public)")
            return
        }

        Log.ssh.info("[RECOVERY] request host=\(self.hostIdentifier, privacy: .public) reason=\(String(describing: reason), privacy: .public) engine=\(self.engineName, privacy: .public)")
        state = .probing
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runProbePipeline(reason: reason)
        }
    }

    private func runProbePipeline(reason: RecoveryReason) async {
        // Phase: probing
        Log.ssh.info("[RECOVERY] probing host=\(self.hostIdentifier, privacy: .public) reason=\(String(describing: reason), privacy: .public)")

        let alive = await performProbe()

        if Task.isCancelled { return }

        if alive {
            Log.ssh.info("[RECOVERY] probe alive host=\(self.hostIdentifier, privacy: .public) -> ready")
            state = .idle
            onProbedAlive?()
            return
        }

        Log.ssh.warning("[RECOVERY] probe failed host=\(self.hostIdentifier, privacy: .public) -> reconnecting")
        await runReconnectPipeline(initialReason: reason)
    }

    private func performProbe() async -> Bool {
        guard let probe else {
            Log.ssh.warning("[RECOVERY] no probe configured, treat as dead")
            return false
        }
        // Probe with 5s timeout - never block indefinitely
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await probe()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func runReconnectPipeline(initialReason: RecoveryReason) async {
        state = .reconnecting(attempt: 1)
        attemptCount = 0
        let limit = maxAttempts
        // Exponential backoff: 1s,2s,4s,8s,16s,30s,60s max per spec
        let backoffSequence: [Duration] = [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8),
            .seconds(16), .seconds(30), .seconds(60)
        ]

        while attemptCount < limit, !Task.isCancelled {
            attemptCount += 1
            let attempt = attemptCount
            state = .reconnecting(attempt: attempt)
            onReconnecting?(attempt, limit)
            Log.ssh.info("[RECOVERY] reconnect attempt \(attempt)/\(limit) host=\(self.hostIdentifier, privacy: .public) reason=\(String(describing: initialReason), privacy: .public)")

            let success = await performReconnect()

            if Task.isCancelled { return }

            if success {
                Log.ssh.info("[RECOVERY] reconnect success host=\(self.hostIdentifier, privacy: .public) attempt=\(attempt, privacy: .public)")
                state = .idle
                attemptCount = 0
                return
            }

            Log.ssh.warning("[RECOVERY] reconnect failed host=\(self.hostIdentifier, privacy: .public) attempt=\(attempt, privacy: .public)")

            if attempt < limit {
                let delay = backoffSequence[min(attempt - 1, backoffSequence.count - 1)]
                state = .backoff(delay: delay)
                Log.ssh.info("[RECOVERY] backoff host=\(self.hostIdentifier, privacy: .public) delay=\(delay, privacy: .public)")
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
        }

        // Exhausted
        Log.ssh.error("[RECOVERY] exhausted host=\(self.hostIdentifier, privacy: .public) attempts=\(limit, privacy: .public)")
        state = .idle
        attemptCount = 0
        onExhausted?()
    }

    private func performReconnect() async -> Bool {
        guard let reconnect else {
            Log.ssh.error("[RECOVERY] no reconnect configured")
            return false
        }
        // Reconnect with timeout - use ReconnectPolicy maxDelay as bound
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await reconnect()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func currentState() -> RecoveryState { state }
}
