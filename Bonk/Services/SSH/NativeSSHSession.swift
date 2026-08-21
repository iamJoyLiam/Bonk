//
//  NativeSSHSession.swift
//  Bonk
//
//  VNext — Native engine session (T2.1).
//  Wraps Citadel SSHClient; multiplexes PTY / Exec / SFTP on one connection.
//

#if os(macOS)
import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore

final class NativeSSHSession: SSHSession, @unchecked Sendable {
    private let client: SSHClient
    private let _endpoint: SSHEndpoint
    private let stateBox = NIOLockedValueBox<SSHSessionState>(.connected)

    var endpoint: SSHEndpoint { _endpoint }
    var state: SSHSessionState { stateBox.withLockedValue { $0 } }

    init(client: SSHClient, endpoint: SSHEndpoint) {
        self.client = client
        self._endpoint = endpoint
    }

    func openPTY(size: TerminalSize) async throws -> any SSHPTYChannel {
        let pty = PTYSession()
        pty.start(client: client, cols: size.cols, rows: size.rows, termType: "xterm-256color")
        // Adapter so PTYSession vends SSHPTYChannel — reuse existing PTYSession as channel
        return PTYSessionChannelAdapter(pty: pty)
    }

    func execute(_ command: String) async throws -> SSHCommandResult {
        let buffer = try await client.executeCommand(command)
        let output = String(buffer: buffer)
        return SSHCommandResult(output: output, exitCode: 0)
    }

    func openSFTP() async throws -> any SFTPChannel {
        let sftp = try await client.openSFTP()
        return CitadelSFTPChannel(sftp: sftp)
    }

    func close() async {
        stateBox.withLockedValue { $0 = .disconnected }
        try? await client.close()
    }
}

// MARK: - Adapters

private final class PTYSessionChannelAdapter: SSHPTYChannel, @unchecked Sendable {
    private let pty: PTYSession
    init(pty: PTYSession) { self.pty = pty }

    var output: AsyncStream<String> { pty.makeRawOutputStream() }

    func write(_ data: Data) async throws {
        try await pty.sendInput(Array(data)[...])
    }

    func resize(cols: Int, rows: Int) async throws {
        try await pty.resize(cols: cols, rows: rows)
    }

    func close() async { pty.close() }
}

private final class CitadelSFTPChannel: SFTPChannel {
    private let sftp: SFTPClient
    init(sftp: SFTPClient) { self.sftp = sftp }
    func close() async { try? await sftp.close() }
}
#endif
