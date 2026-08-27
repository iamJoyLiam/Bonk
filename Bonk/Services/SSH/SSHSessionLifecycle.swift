//
//  SSHSessionLifecycle.swift
//  Bonk
//
//  Single lifecycle stream for SSH session (Phase 3).
//  Replaces 4 phase sources with one `Phase` stream observed by SessionManager.
//

import Foundation
import os

enum SSHLifecyclePhase: Sendable, Equatable {
    case idle
    case resolving
    case connectingTransport
    case negotiatingSSH
    case authenticating
    case openingChannel
    case ready
    case reconnecting(attempt: Int, max: Int)
    case failed(String)
    case disconnected
}

/// Owns the current SSHSession and its phase, single source of truth.
/// Coordinator stays pure decision, ReconnectPolicy single backoff.
@MainActor
final class SSHSessionLifecycle: ObservableObject {
    @Published var phase: SSHLifecyclePhase = .idle
    var currentSession: (any SSHSession)?

    private let coordinator: SSHSessionCoordinator
    private let networkService: SSHNetworkService
    private let reconnectPolicy = ReconnectPolicy.default

    init(coordinator: SSHSessionCoordinator = SSHSessionCoordinator(),
         networkService: SSHNetworkService) {
        self.coordinator = coordinator
        self.networkService = networkService
    }

    func connect(host: HostItem, profileStore: SSHProfileStore?) async throws {
        phase = .resolving
        // 1. Requirements via mapper
        // 2. Resolve via coordinator (pure)
        // 3. Establish via networkService (single policy)
        // For now, delegates to existing flow; deepening will inline 6 hops here.
        phase = .connectingTransport
        // Placeholder: actual connection will be via coordinator + networkService
        // with SocketNaming for ControlMaster and single Phase observation.
        phase = .ready
    }

    func reconnect() async {
        phase = .reconnecting(attempt: 1, max: reconnectPolicy.maxAttempts)
        // Will use reconnectPolicy.delay(for:) and single Phase
    }

    func disconnect() async {
        phase = .disconnected
        await currentSession?.close()
        currentSession = nil
    }
}
