import Foundation
import SwiftData
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
        var ephemeralResult: AuthRetryResult?
    }

    func preparedConfig(for tab: TerminalTab, session: TerminalSession, passwordOverride: String?, ephemeralResult: AuthRetryResult? = nil) -> SSHConnectionConfig? {
        guard let config = resolveConnectionConfig(for: tab, session: session) else { return nil }
        // Ephemeral result (from AuthRetrySheet) takes precedence — supports all auth types without persisting until success
        if let result = ephemeralResult ?? transientAuthResults[tab.id] {
            let pwLen = result.password.count
            let pwFp = pwLen > 0 ? OpenSSHBackend.passwordFingerprint(result.password) : "-"
            let credDesc = result.credentialID == nil ? "nil" : "\(String(describing: result.credentialID))"
            Log.session.info("[AUTH] ephemeral auth override type=\(result.authType.rawValue, privacy: .public) credID=\(credDesc, privacy: .public) pwLen=\(pwLen) fp=\(pwFp, privacy: .public) pemLen=\(result.privateKeyPEM.count) certLen=\(result.certificatePEM.count) tag=\(result.secureEnclaveTag ?? "nil", privacy: .public) host=\(tab.hostItem.host, privacy: .public) user=\(tab.hostItem.username, privacy: .public)")
            if let resolved = authMethod(from: result) {
                // Isolated retry: bypass ControlMaster, fresh process
                Log.session.info("[AUTH_RETRY] isolated retry bypassControlMaster host=\(config.host, privacy: .public) user=\(config.username, privacy: .public) newAuth=\(result.authType.rawValue, privacy: .public)")
                return SSHConnectionConfig(host: config.host, port: config.port, username: config.username, authMethod: resolved, jumpHost: config.jumpHost, maxReconnectAttempts: config.maxReconnectAttempts, baseReconnectDelay: config.baseReconnectDelay, algorithmRequirements: config.algorithmRequirements, bypassControlMaster: true, generation: config.generation)
            } else {
                Log.session.error("[AUTH] ephemeral authMethod nil! type=\(result.authType.rawValue, privacy: .public) pwLen=\(pwLen) credID=\(credDesc, privacy: .public) — fallback to base config")
            }
        }
        guard let override = passwordOverride, !override.isEmpty else { return config }
        Log.session.info("[AUTH] connectTab with override len=\(override.count)")
        return SSHConnectionConfig(
            host: config.host, port: config.port, username: config.username,
            authMethod: .password(override), jumpHost: config.jumpHost,
            maxReconnectAttempts: config.maxReconnectAttempts, baseReconnectDelay: config.baseReconnectDelay,
            bypassControlMaster: ephemeralResult != nil
        )
    }

    private func authMethod(from result: AuthRetryResult) -> SSHAuthMethod? {
        // New input first: typed password overrides vault stale one
        switch result.authType {
        case .password:
            if !result.password.isEmpty { return .password(result.password) }
        case .privateKey:
            if !result.privateKeyPEM.isEmpty { return .privateKey(pemString: result.privateKeyPEM) }
        case .certificate:
            if !result.privateKeyPEM.isEmpty { return .certificate(privateKeyPEM: result.privateKeyPEM, certificatePEM: result.certificatePEM) }
        case .secureEnclave:
            if let tag = result.secureEnclaveTag, !tag.isEmpty { return .secureEnclaveKey(keyTag: tag) }
        }
        // Fallback to vault if no new input
        if let credID = result.credentialID, let ctx = modelContext, let cred = try? ctx.fetch(FetchDescriptor<Credential>(predicate: #Predicate { $0.persistentModelID == credID })).first, let secret = cred.loadSecret(), !secret.isEmpty {
            switch cred.type {
            case .password: return .password(secret)
            case .privateKey: return .privateKey(pemString: secret)
            case .apiKey: return nil
            }
        }
        // Fallback per authType
        switch result.authType {
        case .password: guard !result.password.isEmpty else { return nil }; return .password(result.password)
        case .privateKey: guard !result.privateKeyPEM.isEmpty else { return nil }; return .privateKey(pemString: result.privateKeyPEM)
        case .certificate: guard !result.privateKeyPEM.isEmpty else { return nil }; return .certificate(privateKeyPEM: result.privateKeyPEM, certificatePEM: result.certificatePEM)
        case .secureEnclave: guard let tag = result.secureEnclaveTag, !tag.isEmpty else { return nil }; return .secureEnclaveKey(keyTag: tag)
        }
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
            algorithmRequirements: algos,
            bypassControlMaster: config.bypassControlMaster
        )
    }

    func attachManualPasswordHandler(to service: SSHNetworkService, tab: TerminalTab) async {
        await service.setManualPasswordHandler { [weak tab] password in
            Task { @MainActor in
                guard let tab else { return }
                if let cred = tab.hostItem.credentialRef {
                    cred.storeSecret(password)
                    Log.session.info("[CONNECT] Manual password accepted; updated vault \(cred.name, privacy: .public)")
                } else {
                    tab.hostItem.updateSavedPassword(password)
                    Log.session.info("[CONNECT] Manual password accepted; saved credential updated")
                }
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
                    algorithmRequirements: req,
                    bypassControlMaster: config.bypassControlMaster,
                    generation: config.generation
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
        setPhase(session, to: .fallbacking(destination: .compatibility), host: config.host, engine: "Compatibility", reason: "fallback \(classification.rawValue)")
        try await compatService.connect(config: compatConfig)
        return (compatService, compatConfig, inferred, reason)
    }

    func finalizeConnection(
        tab: TerminalTab,
        session: TerminalSession,
        service: SSHNetworkService,
        context: FinalizeContext
    ) async throws {
        let capturedGen = session.generation
        if let vnext = await service.makeVNextSession(endpoint: SSHEndpoint(host: context.config.host, port: context.config.port)) {
            session.vnextSession = vnext
        }
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        await service.enableReconnection(attempts: 3)
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        // State: authenticating -> openingChannel -> openingPTY -> ready
        setPhase(session, to: .authenticating, host: context.config.host, engine: "Session", reason: "auth")
        // Deterministic gate: awaitAuthFailure instead of fixed sleep
        let earlyAuthFailed = await session.awaitAuthFailure(timeout: .milliseconds(400))
        if earlyAuthFailed || isPhaseFailed(session.phase) { Log.session.info("[FINALIZE] early auth failed before PTY"); return }
        if session.generation != capturedGen { Log.session.info("[FINALIZE] discard stale gen before PTY"); return }
        setPhase(session, to: .openingChannel, host: context.config.host, engine: "Session", reason: "channel")
        setPhase(session, to: .openingPTY, host: context.config.host, engine: "Session", reason: "PTY")
        session.terminalState = .waitingPTY
        if let firstPane = tab.layout.root.paneState {
            try await setupPTYSession(for: tab, pane: firstPane, session: session, service: service)
        }
        // PTY auth may arrive 300-1200ms later; wait 1000ms and keep waitingPTY to block input
        let ptyAuthFailed = await session.awaitAuthFailure(timeout: .milliseconds(1000))
        if ptyAuthFailed || isPhaseFailed(session.phase) { Log.session.info("[FINALIZE] PTY auth failed, suppress ready"); return }
        if session.generation != capturedGen { Log.session.info("[FINALIZE] discard stale gen before ready"); return }
        session.terminalState = .ready
        setPhase(session, to: .ready, host: context.config.host, engine: "Session", reason: "PTY ready")
        session.connectedAt = Date()
        // Deferred persist: write Keychain after 300ms only if still ready
        let passwordOverride = context.passwordOverride
        let ephemeralResult = context.ephemeralResult
        let tabID = tab.id
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let tab, self.tabs.contains(where: { $0.id == tabID }) else { return }
            guard let currentSession = tab.session, currentSession.generation == capturedGen else { return }
            guard currentSession.phase.isReady else {
                Log.session.info("[CRED] deferred persist cancelled — session no longer ready (gen=\(capturedGen.uuidString.prefix(8)))")
                return
            }
            Log.session.info("[CRED] deferred persist confirmed — session still ready after 300ms gen=\(capturedGen.uuidString.prefix(8))")
            if let override = passwordOverride, !override.isEmpty {
                self.persistPassword(override, for: tab)
            }
            // Persist ephemeral retry result on confirmed success
            if let result = ephemeralResult {
                if result.authType == .password, !result.password.isEmpty {
                    // already persisted via passwordOverride
                } else if let credID = result.credentialID, let ctx = self.modelContext, let cred = (try? ctx.fetch(FetchDescriptor<Credential>(predicate: #Predicate { $0.persistentModelID == credID })))?.first {
                    tab.hostItem.credentialRef = cred
                    tab.hostItem.authType = result.authType
                    Log.session.info("[AUTH] persisted vault credential \(cred.name, privacy: .public) for \(tab.hostItem.host, privacy: .public)")
                } else {
                    // Custom auth: clear vault and store PEMs directly
                    tab.hostItem.credentialRef = nil
                    tab.hostItem.authType = result.authType
                    switch result.authType {
                    case .privateKey: tab.hostItem.storePrivateKey(result.privateKeyPEM)
                    case .certificate: tab.hostItem.storePrivateKey(result.privateKeyPEM); tab.hostItem.storeCertificate(result.certificatePEM)
                    case .secureEnclave: if let tag = result.secureEnclaveTag { tab.hostItem.storeSecureEnclaveKeyTag(tag) }
                    case .password: tab.hostItem.storePassword(result.password)
                    }
                    Log.session.info("[AUTH] persisted custom auth \(result.authType.rawValue, privacy: .public) for \(tab.hostItem.host, privacy: .public)")
                }
                self.transientAuthResults[tabID] = nil
            }
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

    private func isPhaseFailed(_ phase: SSHConnectionPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
}
