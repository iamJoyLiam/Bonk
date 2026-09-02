//
//  SSHSessionLifecycle.swift
//  Bonk
//
//  Single lifecycle stream for SSH session (Phase 3).
//  Collapses HostItem→ConfigBuilder→Requirements→ProfileStore→Coordinator→effectiveConfig
//  6 hops into one `connect(host:)` call. SessionManager observes single `phase`.
//

import Combine
import Foundation
import os

enum SSHLifecyclePhase: Sendable, Equatable {
    case idle
    case resolving
    case connectingTransport
    case negotiatingSSH
    case authenticating
    case openingChannel
    case openingPTY
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
    private let profileStore: SSHProfileStore?
    private let hostKeyStore: SSHHostKeyStore
    private let reconnectPolicy = ReconnectPolicy.default

    init(coordinator: SSHSessionCoordinator = SSHSessionCoordinator(),
         networkService: SSHNetworkService,
         profileStore: SSHProfileStore? = nil,
         hostKeyStore: SSHHostKeyStore) {
        self.coordinator = coordinator
        self.networkService = networkService
        self.profileStore = profileStore
        self.hostKeyStore = hostKeyStore
    }

    struct ResolvedConnection: Sendable {
        let config: SSHConnectionConfig
        let effectiveConfig: SSHConnectionConfig
        let requirements: SSHConnectionRequirements
        let decision: SSHConnectionDecision
        let service: SSHNetworkService
    }

    /// 6-hop collapse: HostItem → Config → Requirements → Profile → Coordinator → effectiveConfig → Service
    func resolve(host: HostItem) async -> ResolvedConnection? {
        guard case .success(let config) = SSHConnectionConfigBuilder.makeConfig(for: host) else {
            phase = .failed("resolve config")
            return nil
        }
        return await resolve(config: config, forcedCompatibility: host.forceCompatibility == true)
    }

    /// VNext 优化：直接传入已含 ephemeralResult 的 SSHConnectionConfig，避免 HostItem 持久化 credential 覆盖 retry credential
    func resolve(config: SSHConnectionConfig, forcedCompatibility: Bool = false) async -> ResolvedConnection? {
        phase = .resolving
        let req = SSHRequirementsMapper.requirements(from: config)
        let isForced = forcedCompatibility
        let cached: SSHSessionCoordinator.CachedProfile? = {
            if isForced {
                return SSHSessionCoordinator.CachedProfile(backend: .compatibility, reason: .forcedCompatibility, isValid: true)
            }
            guard let profile = profileStore?.profile(for: req),
                  let backend = profile.backendType, let reason = profile.reason else { return nil }
            return SSHSessionCoordinator.CachedProfile(backend: backend, reason: reason, isValid: true, algorithms: profile.algorithmRequirements)
        }()
        let decision: SSHConnectionDecision
        if isForced {
            decision = .compatibility(reason: .forcedCompatibility)
        } else {
            decision = await coordinator.resolve(request: SSHConnectionRequest(requirements: req), cachedProfile: cached)
        }
        let effective: SSHConnectionConfig
        if case .compatibility = decision, let algos = cached?.algorithms, !algos.isEmpty {
            effective = SSHConnectionConfig(
                host: config.host, port: config.port, username: config.username,
                authMethod: config.authMethod, jumpHost: config.jumpHost,
                maxReconnectAttempts: config.maxReconnectAttempts, baseReconnectDelay: config.baseReconnectDelay,
                algorithmRequirements: algos
            )
        } else {
            effective = config
        }
        let forced: SSHBackendType? = switch decision {
        case .native: .native
        case .compatibility: .compatibility
        case .nativeWithCompatibilityFallback: .native
        }
        let service = SSHNetworkService(hostKeyStore: hostKeyStore)
        #if os(macOS)
        await service.setVNextPreferredBackend(forced)
        #endif
        Log.session.info("[Lifecycle] resolve \(config.host):\(config.port) decision=\(String(describing: decision), privacy: .public)")
        return ResolvedConnection(config: config, effectiveConfig: effective, requirements: req, decision: decision, service: service)
    }

    func connect(host: HostItem) async throws -> SSHNetworkService? {
        guard let resolved = await resolve(host: host) else { return nil }
        phase = .connectingTransport
        currentSession = nil
        // Actual connect will be via SessionManager's existing finalize flow until fully inlined
        return resolved.service
    }

    func disconnect() async {
        phase = .disconnected
        await currentSession?.close()
        currentSession = nil
    }
}
