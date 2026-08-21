//
//  SSHFailureClassification.swift
//  Bonk
//
//  VNext — Failure classification (T1.3).
//  Router depends only on this, never on NIOSSHError / exit codes directly.
//

import Foundation

// MARK: - Phase (where in the handshake the failure occurred)

public enum SSHProtocolPhase: String, Sendable, Hashable, Codable {
    case tcp
    case identification
    case keyExchange
    case hostKeyVerification
    case userAuthentication
    case session
}

// MARK: - Context (what the classifier sees)

public struct SSHFailureContext: Sendable {
    public let phase: SSHProtocolPhase
    public let underlyingError: Error
    public let endpoint: SSHEndpoint?
    public let negotiatedKEX: String?
    public let negotiatedHostKey: String?
    public let negotiatedCipher: String?
    public let negotiatedMAC: String?

    public init(
        phase: SSHProtocolPhase,
        underlyingError: Error,
        endpoint: SSHEndpoint? = nil,
        negotiatedKEX: String? = nil,
        negotiatedHostKey: String? = nil,
        negotiatedCipher: String? = nil,
        negotiatedMAC: String? = nil
    ) {
        self.phase = phase
        self.underlyingError = underlyingError
        self.endpoint = endpoint
        self.negotiatedKEX = negotiatedKEX
        self.negotiatedHostKey = negotiatedHostKey
        self.negotiatedCipher = negotiatedCipher
        self.negotiatedMAC = negotiatedMAC
    }
}

// MARK: - Classification (Router's only switch)

public enum SSHFailureClassification: String, Sendable, Hashable, Codable {
    case transport              // TCP/DNS/超时 — 与引擎无关
    case protocolCompatibility  // KEX / HostKey / Cipher / MAC 协商失败 — 可切 Compatibility
    case backendCapability      // 引擎能力缺失（如 no supported auth methods + password→kbd）
    case authentication         // 凭据错误 — 绝不切
    case configuration          // 本地配置错误
    case unknown

    /// Only these two trigger Native → Compatibility
    public var canFallbackToCompatibility: Bool {
        switch self {
        case .protocolCompatibility, .backendCapability: return true
        case .transport, .authentication, .configuration, .unknown: return false
        }
    }
}

// MARK: - Classifier Protocol (decouples Router from NIOSSH/OpenSSH)

public protocol SSHErrorClassifier: Sendable {
    func classify(_ context: SSHFailureContext) -> SSHFailureClassification
}

// MARK: - Native Classifier (Citadel / NIOSSH)

// NIOSSHError is not imported here to keep this file independent of the
// exact NIOSSH module version. Classification is done by string matching
// on error descriptions + phase, which is stable across fork upgrades.
// When bumping Citadel, add new cases here behind the same interface.
public struct NativeErrorClassifier: SSHErrorClassifier {
    public init() {}

    public func classify(_ context: SSHFailureContext) -> SSHFailureClassification {
        let msg = context.underlyingError.localizedDescription.lowercased()
        let desc = String(describing: context.underlyingError).lowercased()

        // Host key identity mismatch is authentication (security), never compatibility
        if isHostKeyIdentityMismatch(context.underlyingError, msg: msg, desc: desc) {
            return .authentication
        }

        switch context.phase {
        case .tcp, .identification:
            return .transport
        case .keyExchange:
            if isNegotiationFailure(msg: msg, desc: desc) { return .protocolCompatibility }
            return .transport
        case .hostKeyVerification:
            // Algorithm unsupported → compatibility; identity mismatch already handled above
            if isNegotiationFailure(msg: msg, desc: desc) { return .protocolCompatibility }
            return .authentication
        case .userAuthentication:
            if isBackendCapabilityAuthFailure(msg: msg, desc: desc) { return .backendCapability }
            if isAuthenticationFailure(msg: msg, desc: desc) { return .authentication }
            if isNegotiationFailure(msg: msg, desc: desc) { return .protocolCompatibility }
            return .authentication
        case .session:
            return .unknown
        }
    }

    private func isNegotiationFailure(msg: String, desc: String) -> Bool {
        let haystack = msg + " " + desc
        return haystack.contains("keyexchangenegotiationfailure")
            || haystack.contains("unsupportedversion")
            || haystack.contains("remotepeerdoesnotsupportmessage")
            || haystack.contains("invalidhostkeyforkeyexchange")
            || haystack.contains("no matching key exchange")
            || haystack.contains("no matching host key")
            || haystack.contains("no matching cipher")
            || haystack.contains("no matching mac")
    }

    private func isAuthenticationFailure(msg: String, desc: String) -> Bool {
        let haystack = msg + " " + desc
        return haystack.contains("permission denied")
            || haystack.contains("authentication failed")
            || haystack.contains("auth failed")
            || haystack.contains("unknownpublickey")
            || haystack.contains("hostkeymismatch")
    }

    private func isBackendCapabilityAuthFailure(msg: String, desc: String) -> Bool {
        let haystack = msg + " " + desc
        // Server only accepts keyboard-interactive, but we offered password — capability gap, not credential
        // Citadel 0.12 reports this as `allAuthenticationOptionsFailed` (error 4)
        return haystack.contains("no supported authentication methods")
            || haystack.contains("no supported auth")
            || haystack.contains("allauthenticationoptionsfailed")
            || haystack.contains("all authentication options failed")
    }

    private func isHostKeyIdentityMismatch(_ error: Error, msg: String, desc: String) -> Bool {
        if let svc = error as? SSHServiceError, case .hostKeyMismatch = svc { return true }
        let haystack = msg + " " + desc
        return haystack.contains("host key mismatch")
            || haystack.contains("host key verification failed")
            || haystack.contains("fingerprint mismatch")
    }
}

// MARK: - Compatibility (OpenSSH) Classifier

public struct CompatibilityErrorClassifier: SSHErrorClassifier {
    public init() {}

    public func classify(_ context: SSHFailureContext) -> SSHFailureClassification {
        let msg = context.underlyingError.localizedDescription.lowercased()
        // OpenSSH failures are already post-fallback; they should not trigger further fallback
        if msg.contains("permission denied") || msg.contains("authentication failed") {
            return .authentication
        }
        if msg.contains("host key mismatch") || msg.contains("host key verification failed") {
            return .authentication
        }
        return .unknown
    }
}
