//
//  SSHModels.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

import Foundation
import NIOSSH

// MARK: - Connection Configuration

public struct SSHConnectionConfig: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let authMethod: SSHAuthMethod
    public let maxReconnectAttempts: Int
    public let baseReconnectDelay: Duration

    public init(
        host: String,
        port: UInt16 = 22,
        username: String,
        authMethod: SSHAuthMethod,
        maxReconnectAttempts: Int = 5,
        baseReconnectDelay: Duration = .seconds(1)
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.maxReconnectAttempts = maxReconnectAttempts
        self.baseReconnectDelay = baseReconnectDelay
    }
}

// MARK: - Authentication Method

public enum SSHAuthMethod: Sendable, Hashable {
    case password(String)
    case privateKey(pemString: String)
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
            "Host key mismatch!\nExpected: \(expected)\nReceived: \(received)\nThe host key may have changed, or this could be a man-in-the-middle attack."
        case let .connectionFailed(reason):
            "Connection failed: \(reason)"
        case let .reconnectExhausted(attempts):
            "Reconnection failed after \(attempts) attempts."
        }
    }
}
