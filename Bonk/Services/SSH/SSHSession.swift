//
//  SSHSession.swift
//  Bonk
//
//  VNext — Unified session abstraction (T1.2).
//  Upper layers (Terminal / SFTP / AI) depend only on this protocol.
//

import Foundation
import NIOCore

// MARK: - Session State

public enum SSHSessionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnected
}

// MARK: - Channel Abstractions

public struct TerminalSize: Sendable, Hashable, Equatable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}

public struct SSHCommandResult: Sendable, Equatable {
    public var output: String
    public var exitCode: Int32
    public init(output: String, exitCode: Int32 = 0) {
        self.output = output; self.exitCode = exitCode
    }
}

// PTY channel — what SwiftTerm consumes
public protocol SSHPTYChannel: Sendable {
    var output: AsyncStream<String> { get }
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
}

// SFTP channel — unified file operations (T5)
public protocol SFTPChannel: Sendable {
    func realPath() async throws -> String
    func listDirectory(at path: String) async throws -> [SFTPFileEntry]
    func createDirectory(at path: String) async throws
    func remove(at path: String, isDirectory: Bool) async throws
    func upload(_ localURL: URL, to remotePath: String, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws
    func download(_ remotePath: String, to localURL: URL, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws
    func fileExists(at path: String) async -> Bool
    func close() async
}

// Forward channel placeholder (M5)
public protocol SSHForwardChannel: Sendable {
    func close() async
}

// MARK: - Unified Session (only business object, §8.1)

/// Upper layers see only this. Backend is an implementation detail.
public protocol SSHSession: Sendable {
    var endpoint: SSHEndpoint { get }
    var state: SSHSessionState { get }

    func openPTY(size: TerminalSize) async throws -> any SSHPTYChannel
    func execute(_ command: String) async throws -> SSHCommandResult
    func openSFTP() async throws -> any SFTPChannel
    func close() async
}

// MARK: - Notes
// PTYSession is the concrete PTY implementation (Bonk/Services/SSH/PTYSession.swift).
// NativeSSHSession / CompatibilitySSHSession adapters that bridge PTYSession
// to SSHPTYChannel / SSHSession land in T1.4 — not in this foundation slice.
