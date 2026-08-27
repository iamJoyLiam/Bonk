//
//  SSHSessionLifecycle.swift
//  Bonk
//
//  Single lifecycle stream for SSH session (Phase 3).
//  Replaces 4 phase sources (phase/connectionState/terminalState/isClosed)
//  with one `Phase` stream observed by SessionManager.
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
@MainActor
final class SSHSessionLifecycle: ObservableObject {
    @Published var phase: SSHLifecyclePhase = .idle
    var currentSession: (any SSHSession)?

    private let coordinator: SSHSessionCoordinator
    private let networkService: SSHNetworkService

    init(coordinator: SSHSessionCoordinator, networkService: SSHNetworkService) {
        self.coordinator = coordinator
        self.networkService = networkService
    }

    func connect(host: HostItem) async throws {
        phase = .resolving
        // 1. Build requirements via mapper (host -> requirements)
        // 2. Resolve via coordinator (pure decision)
        // 3. Establish via networkService (single reconnect policy)
        // Placeholder: delegates to existing SessionManager flow until T3.2
        phase = .ready
    }

    func disconnect() async {
        phase = .disconnected
        await currentSession?.close()
        currentSession = nil
    }
}
