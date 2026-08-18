//
//  SSHModels.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

import Foundation

// MARK: - Connection Configuration

public struct SSHConnectionConfig: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let authMethod: SSHAuthMethod
    /// Optional OpenSSH ProxyJump target.
    public let jumpHost: SSHJumpHostConfig?
    public let maxReconnectAttempts: Int
    public let baseReconnectDelay: Duration

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: SSHAuthMethod,
        jumpHost: SSHJumpHostConfig? = nil,
        maxReconnectAttempts: Int = 5,
        baseReconnectDelay: Duration = .seconds(1)
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.jumpHost = jumpHost
        self.maxReconnectAttempts = maxReconnectAttempts
        self.baseReconnectDelay = baseReconnectDelay
    }
}

/// Jump host parameters consumed by OpenSSH `ProxyJump`.
///
/// Kept separate from the SwiftData `JumpHost` model so connection services
/// can also use ephemeral jump settings (for example imported SSH config).
public struct SSHJumpHostConfig: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let authMethod: SSHAuthMethod?

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: SSHAuthMethod? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }
}

public enum SSHPortForwardType: Sendable, Hashable {
    case local
    case remote
    case dynamic
}

public struct SSHPortForwardConfiguration: Sendable, Hashable {
    public let type: SSHPortForwardType
    public let localHost: String
    public let localPort: Int
    public let remoteHost: String
    public let remotePort: Int

    public init(
        type: SSHPortForwardType,
        localHost: String,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) {
        self.type = type
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

// MARK: - Authentication Method

public enum SSHAuthMethod: Sendable, Hashable {
    case password(String)
    case privateKey(pemString: String)
    case certificate(privateKeyPEM: String, certificatePEM: String)
    /// Secure Enclave P256 key (Touch ID / password required)
    case secureEnclaveKey(keyTag: String)
}

// MARK: - Connection State

public enum SSHConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, maxAttempts: Int)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var colorName: String {
        switch self {
        case .connected: "green"
        case .connecting, .reconnecting: "yellow"
        case .disconnected: "gray"
        }
    }
}

// MARK: - Host Key Fingerprint

public struct SSHHostFingerprint: Sendable, Hashable, Codable {
    public let hash: String

    public init(hash: String) {
        self.hash = hash
    }
}

// MARK: - Host Key Store Protocol

public protocol SSHHostKeyStore: Sendable {
    func knownFingerprint(for host: String, port: UInt16) async -> SSHHostFingerprint?
    func saveFingerprint(_ fingerprint: SSHHostFingerprint, for host: String, port: UInt16) async
}

// MARK: - Errors

public enum SSHServiceError: Error, Sendable, LocalizedError {
    case alreadyConnected
    case notConnected
    case hostKeyMismatch(expected: String, received: String)
    case connectionFailed(String)
    case reconnectExhausted(attempts: Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "Already connected to this host."
        case .notConnected:
            "Not connected to any host."
        case let .hostKeyMismatch(expected, received):
            "Host key mismatch!\nExpected: \(expected)\nReceived: \(received)\n"
                + "The host key may have changed, or this could be a man-in-the-middle attack."
        case let .connectionFailed(reason):
            "Connection failed: \(reason)"
        case let .reconnectExhausted(attempts):
            "Reconnection failed after \(attempts) attempts."
        }
    }
}
