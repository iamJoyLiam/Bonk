//
//  SSHSessionCoordinator.swift
//  Bonk
//
//  VNext — Connection Resolver (T1.4).
//  Decides Native vs Compatibility; single retry on compatibility failure only.
//

import Foundation

// MARK: - Request

public struct SSHConnectionRequest: Sendable, Hashable {
    public let requirements: SSHConnectionRequirements
    public init(requirements: SSHConnectionRequirements) {
        self.requirements = requirements
    }
}

// MARK: - Decision

public enum SSHConnectionDecision: Sendable, Equatable {
    case native
    case compatibility(reason: SSHBackendReason)
    case nativeWithCompatibilityFallback
}

// MARK: - Coordinator

public actor SSHSessionCoordinator {
    private let nativeCapabilities: SSHBackendCapabilities
    private let compatibilityCapabilities: SSHBackendCapabilities
    private let nativeClassifier: any SSHErrorClassifier
    private let compatibilityClassifier: any SSHErrorClassifier

    public init(
        nativeCapabilities: SSHBackendCapabilities = .native,
        compatibilityCapabilities: SSHBackendCapabilities = .compatibility,
        nativeClassifier: any SSHErrorClassifier = NativeErrorClassifier(),
        compatibilityClassifier: any SSHErrorClassifier = CompatibilityErrorClassifier()
    ) {
        self.nativeCapabilities = nativeCapabilities
        self.compatibilityCapabilities = compatibilityCapabilities
        self.nativeClassifier = nativeClassifier
        self.compatibilityClassifier = compatibilityClassifier
    }

    // MARK: - Lightweight cached decision (T1.4; SwiftData model lands in T4.1)
    public struct CachedProfile: Sendable, Equatable {
        public let backend: SSHBackendType
        public let reason: SSHBackendReason
        public let isValid: Bool
        public let algorithms: SSHAlgorithmRequirements?
        public init(backend: SSHBackendType, reason: SSHBackendReason, isValid: Bool = true, algorithms: SSHAlgorithmRequirements? = nil) {
            self.backend = backend; self.reason = reason; self.isValid = isValid; self.algorithms = algorithms
        }
    }

    // MARK: Resolve (pure, no I/O)

    public func resolve(
        request: SSHConnectionRequest,
        cachedProfile: CachedProfile? = nil
    ) -> SSHConnectionDecision {
        // 1. Cached profile hit (valid, not expired, fingerprint matches)
        if let p = cachedProfile, p.isValid {
            switch p.backend {
            case .native: return .native
            case .compatibility: return .compatibility(reason: p.reason)
            }
        }

        let req = request.requirements

        // 2. Static policy / capability checks — no probe needed
        // Secure Enclave is Native-only (platform capability)
        if req.authentication == .secureEnclave {
            // Native is the only engine with Secure Enclave custom auth
            return .native
        }
        if req.requiresCertificate || req.authentication == .certificate {
            return .compatibility(reason: .forcedCompatibility)
        }
        if req.keyAlgorithm == .rsa {
            // Native 0.3.6 has no rsa-sha2
            return .compatibility(reason: .hostKeyMismatch)
        }
        if req.requiresKeyboardInteractive || req.authentication == .keyboardInteractive {
            return .compatibility(reason: .noKbdInteractive)
        }
        if req.authentication == .agent || req.requiresAgent {
            return .compatibility(reason: .noKbdInteractive)
        }
        if !req.route.isDirect {
            // v1 policy: any hop → Compatibility (Citadel jump exists but not mature)
            return .compatibility(reason: .jumpHost)
        }
        if req.service == .forward {
            // v1 policy: Forward always via Compatibility (includes dynamic -D) (§9)
            return .compatibility(reason: .modern)
        }

        // 3. Capability check — does Native support this request?
        let nativeBackend = _NativeBackendStub(capabilities: nativeCapabilities)
        if !nativeBackend.supports(req) {
            // Should have been caught above; fallback to Compatibility
            return .compatibility(reason: .kexMismatch)
        }

        // 4. Unknown endpoint → try Native, fallback on compatibility failure
        return .nativeWithCompatibilityFallback
    }

    // MARK: Connect (with single fallback)

    /// Connect with one compatibility fallback. `connectNative` / `connectCompatibility`
    /// are injected so T1.4 is testable without real SSH.
    public func connect(
        request: SSHConnectionRequest,
        cachedProfile: CachedProfile? = nil,
        connectNative: @Sendable () async throws -> any SSHSession,
        connectCompatibility: @Sendable () async throws -> any SSHSession,
        onCompatibilityFallback: (@Sendable (SSHFailureContext) -> Void)? = nil
    ) async throws -> any SSHSession {
        let decision = resolve(request: request, cachedProfile: cachedProfile)

        switch decision {
        case .native:
            return try await connectNative()
        case .compatibility:
            return try await connectCompatibility()
        case .nativeWithCompatibilityFallback:
            do {
                return try await connectNative()
            } catch {
                // Build context from the thrown error. Phase is userAuthentication by default
                // for auth-stage errors; keyExchange for negotiation errors — classifier refines.
                let phase = Self.inferPhase(from: error)
                let ctx = SSHFailureContext(
                    phase: phase,
                    underlyingError: error,
                    endpoint: request.requirements.endpoint
                )
                let classification = nativeClassifier.classify(ctx)
                guard classification.canFallbackToCompatibility else { throw error }
                onCompatibilityFallback?(ctx)
                return try await connectCompatibility()
            }
        }
    }

    private static func inferPhase(from error: Error) -> SSHProtocolPhase {
        let msg = (error.localizedDescription + " " + String(describing: error)).lowercased()
        if msg.contains("keyexchangenegotiationfailure") || msg.contains("no matching key exchange")
            || msg.contains("no matching host key") || msg.contains("no matching cipher") {
            return .keyExchange
        }
        if msg.contains("host key") { return .hostKeyVerification }
        if msg.contains("permission denied") || msg.contains("no supported authentication")
            || msg.contains("unknownpublickey") {
            return .userAuthentication
        }
        if msg.contains("timed out") || msg.contains("refused") || msg.contains("unreachable")
            || msg.contains("could not resolve") {
            return .tcp
        }
        return .keyExchange
    }
}

// MARK: - Minimal stub for capability check

private struct _NativeBackendStub: SSHBackend {
    let capabilities: SSHBackendCapabilities
    var type: SSHBackendType { .native }
}
