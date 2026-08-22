import Foundation
import os.log

// MARK: - VNext routing helpers (M1-M5)
// Extracted from SessionManager.connectTab to keep cyclomatic complexity <12

extension SessionManager {
    struct VNextRouting {
        var requirements: SSHConnectionRequirements
        var cached: SSHSessionCoordinator.CachedProfile?
        var decision: SSHConnectionDecision
    }

    struct FallbackInfo {
        var didFallback: Bool
        var algorithms: SSHAlgorithmRequirements?
        var reason: SSHBackendReason
    }

    struct FinalizeContext {
        var config: SSHConnectionConfig
        var effectiveConfig: SSHConnectionConfig
        var vnextReq: SSHConnectionRequirements
        var vnextDecision: SSHConnectionDecision
        var fallback: FallbackInfo?
        var passwordOverride: String?
    }

    func preparedConfig(for tab: TerminalTab, session: TerminalSession, passwordOverride: String?) -> SSHConnectionConfig? {
        guard let config = resolveConnectionConfig(for: tab, session: session) else { return nil }
        guard let override = passwordOverride, !override.isEmpty else { return config }
        Log.session.info("[AUTH] connectTab with override len=\(override.count)")
        Self.cleanupHostControlSockets(username: config.username, host: config.host, port: config.port)
        return SSHConnectionConfig(
            host: config.host, port: config.port, username: config.username,
            authMethod: .password(override), jumpHost: config.jumpHost,
            maxReconnectAttempts: config.maxReconnectAttempts, baseReconnectDelay: config.baseReconnectDelay
        )
    }

    func vnextRouting(for config: SSHConnectionConfig, host: HostItem) async -> VNextRouting {
        let req = SSHRequirementsMapper.requirements(from: config)
        let isForced = host.forceCompatibility == true
        let cached: SSHSessionCoordinator.CachedProfile? = {
            if isForced {
                Log.session.info("[VNext] Forced compatibility for \(config.host):\(config.port) (host toggle)")
                return SSHSessionCoordinator.CachedProfile(backend: .compatibility, reason: .forcedCompatibility, isValid: true, algorithms: nil)
            }
            guard let profile = vnextProfileStore?.profile(for: req),
                  let backend = profile.backendType, let reason = profile.reason else { return nil }
            Log.session.info("[VNext] Cache hit[\(profile.effectiveHitCount)] TTL \(Int(profile.adaptiveTTL/3600/24))d: \(profile.backendRaw)/\(profile.reasonRaw) — \(profile.host):\(profile.port)")
            return SSHSessionCoordinator.CachedProfile(backend: backend, reason: reason, isValid: true, algorithms: profile.algorithmRequirements)
        }()
        let decision: SSHConnectionDecision
        if isForced {
            decision = .compatibility(reason: .forcedCompatibility)
        } else {
            decision = await vnextCoordinator.resolve(request: SSHConnectionRequest(requirements: req), cachedProfile: cached)
        }
        return VNextRouting(requirements: req, cached: cached, decision: decision)
    }

    func logVNextDecision(_ decision: SSHConnectionDecision, config: SSHConnectionConfig, requirements: SSHConnectionRequirements) {
        switch decision {
        case .native:
            Log.session.info("[VNext] Decision: native — \(config.host):\(config.port) auth=\(String(describing: requirements.authentication))")
        case .compatibility(let reason):
            Log.session.info("[VNext] Decision: compatibility(\(reason.rawValue)) — \(config.host):\(config.port)")
        case .nativeWithCompatibilityFallback:
            Log.session.info("[VNext] Decision: nativeWithCompatibilityFallback — \(config.host):\(config.port) (will try Native, fallback on compatibility failure)")
        }
    }

    func makeVNextService(for decision: SSHConnectionDecision) async -> SSHNetworkService {
        let forced: SSHBackendType? = switch decision {
        case .native: .native
        case .compatibility: .compatibility
        case .nativeWithCompatibilityFallback: .native
        }
        let service = SSHNetworkService(hostKeyStore: hostKeyStore)
        #if os(macOS)
        await service.setVNextPreferredBackend(forced)
        #endif
        return service
    }

    func effectiveConfig(for config: SSHConnectionConfig, decision: SSHConnectionDecision, cached: SSHSessionCoordinator.CachedProfile?) -> SSHConnectionConfig {
        guard case .compatibility = decision, let algos = cached?.algorithms, !algos.isEmpty else { return config }
        return SSHConnectionConfig(
            host: config.host, port: config.port, username: config.username,
            authMethod: config.authMethod, jumpHost: config.jumpHost,
            maxReconnectAttempts: config.maxReconnectAttempts, baseReconnectDelay: config.baseReconnectDelay,
            algorithmRequirements: algos
        )
    }

    func attachManualPasswordHandler(to service: SSHNetworkService, tab: TerminalTab) async {
        await service.setManualPasswordHandler { [weak tab] password in
            Task { @MainActor in
                tab?.hostItem.updateSavedPassword(password)
                Log.session.info("[CONNECT] Manual password accepted; saved credential updated")
            }
        }
    }

    func handleNativeFallback(
        error: Error,
        decision: SSHConnectionDecision,
        config: SSHConnectionConfig,
        requirements: SSHConnectionRequirements,
        currentService: SSHNetworkService,
        session: TerminalSession,
        tab: TerminalTab
    ) async throws -> (service: SSHNetworkService, compatConfig: SSHConnectionConfig, algorithms: SSHAlgorithmRequirements?, reason: SSHBackendReason) {
        switch decision {
        case .native, .nativeWithCompatibilityFallback: break
        case .compatibility: throw error
        }
        let phase: SSHProtocolPhase = {
            let text = (error.localizedDescription + " " + String(describing: error)).lowercased()
            if text.contains("keyexchangenegotiationfailure") || text.contains("no matching") { return .keyExchange }
            if text.contains("host key") { return .hostKeyVerification }
            if text.contains("permission denied") || text.contains("no supported authentication") { return .userAuthentication }
            return .keyExchange
        }()
        let ctx = SSHFailureContext(phase: phase, underlyingError: error, endpoint: requirements.endpoint)
        let classification = NativeErrorClassifier().classify(ctx)
        guard classification.canFallbackToCompatibility else { throw error }
        Log.session.info("[VNext] Native failed (\(classification.rawValue)) — falling back to Compatibility: \(error.localizedDescription)")
        var inferred: SSHAlgorithmRequirements?
        let compatConfig: SSHConnectionConfig = {
            if let req = Self.inferAlgorithmRequirements(from: error), !req.isEmpty {
                Log.session.info("[VNext] Inferred compat algorithms: kex=\(req.kex) hostKey=\(req.hostKey)")
                inferred = req
                return SSHConnectionConfig(
                    host: config.host, port: config.port, username: config.username,
                    authMethod: config.authMethod, jumpHost: config.jumpHost,
                    maxReconnectAttempts: config.maxReconnectAttempts, baseReconnectDelay: config.baseReconnectDelay,
                    algorithmRequirements: req
                )
            }
            return config
        }()
        let reason: SSHBackendReason = switch classification {
        case .protocolCompatibility where phase == .hostKeyVerification: .hostKeyMismatch
        case .protocolCompatibility: .kexMismatch
        case .backendCapability: .noKbdInteractive
        default: .kexMismatch
        }
        let compatService = await makeVNextService(for: .compatibility(reason: reason))
        session.sshService = compatService
        observeStateChanges(for: tab, session: session, service: compatService)
        await attachManualPasswordHandler(to: compatService, tab: tab)
        setPhase(session, to: .fallbacking(to: .compatibility), host: config.host, engine: "Compatibility", reason: "fallback \(classification.rawValue)")
        try await compatService.connect(config: compatConfig)
        return (compatService, compatConfig, inferred, reason)
    }

    func finalizeConnection(
        tab: TerminalTab,
        session: TerminalSession,
        service: SSHNetworkService,
        context: FinalizeContext
    ) async throws {
        if let vnext = await service.makeVNextSession(endpoint: SSHEndpoint(host: context.config.host, port: context.config.port)) {
            session.vnextSession = vnext
        }
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        await service.enableReconnection(attempts: 3)
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        setPhase(session, to: .openingChannel, host: context.config.host, engine: "Session", reason: "PTY")
        session.terminalState = .waitingPTY
        if let firstPane = tab.layout.root.paneState {
            try await setupPTYSession(for: tab, pane: firstPane, session: session, service: service)
        }
        session.terminalState = .ready
        setPhase(session, to: .ready, host: context.config.host, engine: "Session", reason: "PTY ready")
        session.connectedAt = Date()
        if let override = context.passwordOverride, !override.isEmpty {
            persistPassword(override, for: tab)
        }
        if let store = vnextProfileStore {
            let (backend, reason, algos): (SSHBackendType, SSHBackendReason, SSHAlgorithmRequirements?) = switch context.vnextDecision {
            case .native where context.fallback?.didFallback == true:
                (.compatibility, context.fallback!.reason, context.fallback!.algorithms)
            case .native: (.native, .modern, nil)
            case .compatibility(let requestReason): (.compatibility, requestReason, context.effectiveConfig.algorithmRequirements)
            case .nativeWithCompatibilityFallback where context.fallback?.didFallback == true:
                (.compatibility, context.fallback!.reason, context.fallback!.algorithms)
            case .nativeWithCompatibilityFallback: (.native, .modern, nil)
            }
            let classification: SSHFailureClassification? = context.fallback?.didFallback == true ? .protocolCompatibility : nil
            store.save(context.vnextReq, backend: backend, reason: reason, classification: classification, algorithms: algos)
            Log.session.info("[VNext] Profile saved: \(backend.rawValue)/\(reason.rawValue) — \(context.config.host):\(context.config.port)")
        }
    }
}
