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

// MARK: - Operation (what was being done when failure occurred) per hard constraint 2

public enum SSHOperation: String, Sendable, Hashable, Codable {
    case connect
    case authenticate
    case openSession
    case terminalInput
    case terminalOutput
    case exec
    case sftpRead
    case sftpWrite
    case portForward
    case reconnect
}

// MARK: - Context (what the classifier sees)

public struct SSHFailureContext: Sendable {
    public let phase: SSHProtocolPhase
    public let operation: SSHOperation
    public let backend: SSHBackendType?
    public let underlyingError: Error
    public let endpoint: SSHEndpoint?
    public let negotiatedKEX: String?
    public let negotiatedHostKey: String?
    public let negotiatedCipher: String?
    public let negotiatedMAC: String?

    public init(
        phase: SSHProtocolPhase,
        underlyingError: Error,
        operation: SSHOperation = .connect,
        backend: SSHBackendType? = nil,
        endpoint: SSHEndpoint? = nil,
        negotiatedKEX: String? = nil,
        negotiatedHostKey: String? = nil,
        negotiatedCipher: String? = nil,
        negotiatedMAC: String? = nil
    ) {
        self.phase = phase
        self.operation = operation
        self.backend = backend
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
    case transport              // TCP/DNS/ —
    case protocolCompatibility  // KEX / HostKey / Cipher / MAC  —  Compatibility
    case backendCapability      // no supported auth methods + password→kbd
    case authentication         //  
    case hostKeyVerification    // HostKey  — Security Boundary，
    case channel                // Channel/SFTP  —  reconnect， Policy
    case configuration          //  
    case unknown

    /// Is this error a host-key *trust* failure — a key that did not match what
    /// we already accepted?
    ///
    /// One definition, deliberately shared. The session path needs it to decide
    /// whether it may switch SSH backend (`canFallbackToCompatibility` already
    /// excludes `.hostKeyVerification`), and the SFTP path needs it to decide
    /// whether it may switch transport. They are the same question, and two
    /// definitions is how the SFTP path came to treat a rejected key as a
    /// transport problem.
    ///
    /// The type check alone is not sufficient. NIO surfaces some handshake
    /// failures as an opaque `NSError` whose only signal is the message, which
    /// is why the native classifier has always matched on text as well; a
    /// predicate that only understood the enum would let those through.
    static func isHostKeyTrustFailure(_ error: Error) -> Bool {
        if let svc = error as? SSHServiceError, case .hostKeyMismatch = svc { return true }
        let nsError = error as NSError
        let described = (error as? LocalizedError)?.errorDescription ?? ""
        let text = nsError.localizedDescription + " " + described
        return text.contains("host key mismatch")
            || text.contains("host key verification failed")
            || text.contains("fingerprint mismatch")
    }

    /// Only these two trigger Native → Compatibility
    public var canFallbackToCompatibility: Bool {
        switch self {
        case .protocolCompatibility, .backendCapability: return true
        case .transport, .authentication, .hostKeyVerification, .channel, .configuration, .unknown: return false
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

        // Host key identity mismatch is hostKeyVerification (security), never compatibility nor authentication
        if isHostKeyIdentityMismatch(context.underlyingError, msg: msg, desc: desc) {
            return .hostKeyVerification
        }

        // Operation-aware: sftp/channel errors must not be treated as authentication even if string contains permission denied
        if context.operation == .sftpRead || context.operation == .sftpWrite || context.operation == .portForward {
            if isAuthenticationFailure(msg: msg, desc: desc) { return .channel }
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
            return .hostKeyVerification
        case .userAuthentication:
            if isBackendCapabilityAuthFailure(msg: msg, desc: desc) { return .backendCapability }
            // For userAuthentication phase, permission denied is authentication unless it's explicitly sftp operation (hard constraint 2 refined)
            if context.operation == .sftpRead || context.operation == .sftpWrite {
                if isAuthenticationFailure(msg: msg, desc: desc) { return .channel }
            } else {
                if isAuthenticationFailure(msg: msg, desc: desc) { return .authentication }
            }
            if isNegotiationFailure(msg: msg, desc: desc) { return .protocolCompatibility }
            return .authentication
        case .session:
            // Channel failures during session should be channel, not transport
            if context.operation == .sftpRead || context.operation == .sftpWrite { return .channel }
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
        // The classifier sees the transport's own message text, which is richer
        // than `localizedDescription`, so it is offered to the shared predicate
        // rather than the definition being restated here.
        let haystack = msg + " " + desc
        if haystack.contains("host key mismatch")
            || haystack.contains("host key verification failed")
            || haystack.contains("fingerprint mismatch")
        {
            return true
        }
        return SSHFailureClassification.isHostKeyTrustFailure(error)
    }
}

// MARK: - Compatibility (OpenSSH) Classifier

public struct CompatibilityErrorClassifier: SSHErrorClassifier {
    public init() {}

    public func classify(_ context: SSHFailureContext) -> SSHFailureClassification {
        let msg = context.underlyingError.localizedDescription.lowercased()
        // OpenSSH failures are already post-fallback; they should not trigger further fallback
        // HostKey mismatch is security boundary, not authentication
        if msg.contains("host key mismatch") || msg.contains("host key verification failed") || msg.contains("fingerprint mismatch") {
            return .hostKeyVerification
        }
        if context.operation == .sftpRead || context.operation == .sftpWrite || context.operation == .portForward {
            if msg.contains("permission denied") { return .channel }
        }
        if msg.contains("permission denied") || msg.contains("authentication failed") {
            // Only authenticate if operation is authenticate, otherwise channel
            if context.operation == .authenticate || context.phase == .userAuthentication { return .authentication }
            return .channel
        }
        return .unknown
    }
}
