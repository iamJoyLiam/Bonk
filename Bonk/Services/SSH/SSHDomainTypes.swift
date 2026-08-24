//
//  SSHDomainTypes.swift
//  Bonk
//
//  VNext Hybrid SSH — Domain types for routing (T1.1).
//  No behavior, no SwiftData, no sensitive data (passwords/keys) here.
//  Sensitive values stay in SSHAuthMethod / Keychain.
//

import Foundation

/// Single source of truth for SSH port defaults — replaces scattered `22`/`32,222` literals.
public enum SSHConstants {
    public static let defaultPort: Int = 22
    public static let defaultPortUInt16: UInt16 = 22
}

// MARK: - Endpoint & Route

public struct SSHEndpoint: Sendable, Hashable, Codable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = UInt16(SSHConstants.defaultPortUInt16)) {
        self.host = host
        self.port = port
    }
}

public struct SSHRoute: Sendable, Hashable, Codable, Equatable {
    public var hops: [SSHEndpoint]

    public init(hops: [SSHEndpoint] = []) {
        self.hops = hops
    }

    public var isDirect: Bool { hops.isEmpty }

    public static var direct: SSHRoute { SSHRoute(hops: []) }
}

// MARK: - Authentication (capability tag, no sensitive payload)

public enum SSHRoutingAuthMethod: String, Sendable, Hashable, Codable, CaseIterable {
    case password
    case publicKey
    case certificate
    case secureEnclave
    case keyboardInteractive
    case agent
}

public enum SSHKeyAlgorithm: String, Sendable, Hashable, Codable, CaseIterable {
    case ed25519
    case ecdsa
    case rsa
}

// MARK: - Service Requirement

public enum SSHServiceRequirement: String, Sendable, Hashable, Codable, CaseIterable {
    case terminal
    case exec
    case sftp
    case forward
}

// MARK: - Algorithm Requirements (per-endpoint compatibility, §6.2)

public struct SSHAlgorithmRequirements: Sendable, Hashable, Codable, Equatable {
    public var kex: [String]
    public var hostKey: [String]
    public var cipher: [String]
    public var mac: [String]

    public init(kex: [String] = [], hostKey: [String] = [], cipher: [String] = [], mac: [String] = []) {
        self.kex = kex
        self.hostKey = hostKey
        self.cipher = cipher
        self.mac = mac
    }

    public var isEmpty: Bool { kex.isEmpty && hostKey.isEmpty && cipher.isEmpty && mac.isEmpty }
}

// MARK: - Backend Type & Reason

public enum SSHBackendType: String, Sendable, Hashable, Codable, CaseIterable {
    case native
    case compatibility
}

public enum SSHBackendReason: String, Sendable, Hashable, Codable, CaseIterable {
    case modern                 // native 成功
    case kexMismatch            // capability
    case hostKeyMismatch
    case cipherMismatch
    case noKbdInteractive       // capability (no supported auth methods)
    case jumpHost               // policy
    case forcedCompatibility    // 用户手动指定
}

// MARK: - Connection Requirements (input to Router, §5.1)

// Non-sensitive routing input — never carries password / private key material.
public struct SSHConnectionRequirements: Sendable, Hashable, Equatable {
    public let authentication: SSHRoutingAuthMethod
    public let keyAlgorithm: SSHKeyAlgorithm?
    public let requiresKeyboardInteractive: Bool
    public let requiresCertificate: Bool
    public let requiresAgent: Bool
    public let route: SSHRoute
    public let service: SSHServiceRequirement
    public let endpoint: SSHEndpoint

    public init(
        authentication: SSHRoutingAuthMethod,
        keyAlgorithm: SSHKeyAlgorithm? = nil,
        requiresKeyboardInteractive: Bool = false,
        requiresCertificate: Bool = false,
        requiresAgent: Bool = false,
        route: SSHRoute = .direct,
        service: SSHServiceRequirement = .terminal,
        endpoint: SSHEndpoint
    ) {
        self.authentication = authentication
        self.keyAlgorithm = keyAlgorithm
        self.requiresKeyboardInteractive = requiresKeyboardInteractive
        self.requiresCertificate = requiresCertificate
        self.requiresAgent = requiresAgent
        self.route = route
        self.service = service
        self.endpoint = endpoint
    }
}

// MARK: - Backend Capabilities (what an engine provides, §5.1)

public struct SSHConnectionCapabilities: Sendable, Hashable, Equatable {
    public var password: Bool
    public var publicKey: Bool
    public var ed25519: Bool
    public var ecdsa: Bool
    public var rsa: Bool
    public var keyboardInteractive: Bool
    public var certificate: Bool
    public var agent: Bool
    public var legacyKEX: Bool
    public var legacyHostKey: Bool
    public var legacyCipher: Bool
    public var proxyJump: Bool

    public init(
        password: Bool = false,
        publicKey: Bool = false,
        ed25519: Bool = false,
        ecdsa: Bool = false,
        rsa: Bool = false,
        keyboardInteractive: Bool = false,
        certificate: Bool = false,
        agent: Bool = false,
        legacyKEX: Bool = false,
        legacyHostKey: Bool = false,
        legacyCipher: Bool = false,
        proxyJump: Bool = false
    ) {
        self.password = password
        self.publicKey = publicKey
        self.ed25519 = ed25519
        self.ecdsa = ecdsa
        self.rsa = rsa
        self.keyboardInteractive = keyboardInteractive
        self.certificate = certificate
        self.agent = agent
        self.legacyKEX = legacyKEX
        self.legacyHostKey = legacyHostKey
        self.legacyCipher = legacyCipher
        self.proxyJump = proxyJump
    }
}

public struct SSHServiceCapabilities: Sendable, Hashable, Equatable {
    public var terminal: Bool
    public var exec: Bool
    public var sftp: Bool
    public var directForward: Bool
    public var reverseForward: Bool
    public var dynamicForward: Bool

    public init(
        terminal: Bool = false,
        exec: Bool = false,
        sftp: Bool = false,
        directForward: Bool = false,
        reverseForward: Bool = false,
        dynamicForward: Bool = false
    ) {
        self.terminal = terminal
        self.exec = exec
        self.sftp = sftp
        self.directForward = directForward
        self.reverseForward = reverseForward
        self.dynamicForward = dynamicForward
    }
}

public struct SSHBackendCapabilities: Sendable, Hashable, Equatable {
    public var connection: SSHConnectionCapabilities
    public var service: SSHServiceCapabilities

    public init(connection: SSHConnectionCapabilities, service: SSHServiceCapabilities) {
        self.connection = connection
        self.service = service
    }
}

// Known capability sets for the two engines (locked deps: Citadel ae8562f + Wellz26 0.3.6)
public extension SSHBackendCapabilities {
    static var native: SSHBackendCapabilities {
        SSHBackendCapabilities(
            connection: SSHConnectionCapabilities(
                password: true,
                publicKey: true,
                ed25519: true,
                ecdsa: true,
                rsa: false,
                keyboardInteractive: false,
                certificate: false,
                agent: false,
                legacyKEX: false,
                legacyHostKey: false,
                legacyCipher: false,
                proxyJump: true // Citadel jump(to:) exists, but v1 policy keeps jump on Compatibility
            ),
            service: SSHServiceCapabilities(
                terminal: true,
                exec: true,
                sftp: true,
                directForward: true,
                reverseForward: true,
                dynamicForward: false
            )
        )
    }

    static var compatibility: SSHBackendCapabilities {
        SSHBackendCapabilities(
            connection: SSHConnectionCapabilities(
                password: true,
                publicKey: true,
                ed25519: true,
                ecdsa: true,
                rsa: true,
                keyboardInteractive: true,
                certificate: true,
                agent: true,
                legacyKEX: true,
                legacyHostKey: true,
                legacyCipher: true,
                proxyJump: true
            ),
            service: SSHServiceCapabilities(
                terminal: true,
                exec: true,
                sftp: true,
                directForward: true,
                reverseForward: true,
                dynamicForward: true
            )
        )
    }
}

// MARK: - Backend Protocol (capability query, §5.1)

public protocol SSHBackend: Sendable {
    var type: SSHBackendType { get }
    var capabilities: SSHBackendCapabilities { get }
    func supports(_ requirements: SSHConnectionRequirements) -> Bool
}

public extension SSHBackend {
    func supports(_ requirements: SSHConnectionRequirements) -> Bool {
        let c = capabilities.connection
        let s = capabilities.service

        // Authentication
        switch requirements.authentication {
        case .password:
            guard c.password else { return false }
        case .publicKey:
            guard c.publicKey else { return false }
            if let algo = requirements.keyAlgorithm {
                switch algo {
                case .ed25519: guard c.ed25519 else { return false }
                case .ecdsa: guard c.ecdsa else { return false }
                case .rsa: guard c.rsa else { return false }
                }
            }
        case .certificate:
            guard c.certificate else { return false }
        case .secureEnclave:
            // Only Native provides Secure Enclave custom auth (see §3.1)
            guard c.publicKey && type == .native else { return false }
        case .keyboardInteractive:
            guard c.keyboardInteractive else { return false }
        case .agent:
            guard c.agent else { return false }
        }

        if requirements.requiresKeyboardInteractive, !c.keyboardInteractive { return false }
        if requirements.requiresCertificate, !c.certificate { return false }
        if requirements.requiresAgent, !c.agent { return false }

        // Service — v1: compatibility-only services stay on Compatibility
        // (forward/dynamic stays Compatibility by policy even though Native has direct/remote;
        //  policy layer decides, this is pure capability check)
        switch requirements.service {
        case .terminal: guard s.terminal else { return false }
        case .exec: guard s.exec else { return false }
        case .sftp: guard s.sftp else { return false }
        case .forward:
            // forward requires at least one of direct/reverse/dynamic
            guard s.directForward || s.reverseForward || s.dynamicForward else { return false }
        }

        return true
    }
}

// MARK: - Capability Fingerprint (for cache invalidation, §6.3)

public struct SSHCapabilityFingerprint: Sendable, Hashable, Codable, Equatable {
    public var citadelVersion: String
    public var niosshVersion: String

    public init(citadelVersion: String, niosshVersion: String) {
        self.citadelVersion = citadelVersion
        self.niosshVersion = niosshVersion
    }

    public static var current: SSHCapabilityFingerprint {
        // Locked deps — update when bumping Citadel / swift-nio-ssh
        SSHCapabilityFingerprint(citadelVersion: "ae8562f", niosshVersion: "0.3.6-wellz26")
    }
}
