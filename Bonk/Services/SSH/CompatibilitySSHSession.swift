//
//  CompatibilitySSHSession.swift
//  Bonk
//
//  VNext — Compatibility engine session (T2.1).
//  Wraps OpenSSHBackend; same SSHSession interface as Native.
//

#if os(macOS)
import Foundation

final class CompatibilitySSHSession: SSHSession, @unchecked Sendable {
    private let backend: OpenSSHBackend
    private let _endpoint: SSHEndpoint

    var endpoint: SSHEndpoint { _endpoint }
    var state: SSHSessionState { .connected }

    init(backend: OpenSSHBackend, endpoint: SSHEndpoint) {
        self.backend = backend
        self._endpoint = endpoint
    }

    func openPTY(size: TerminalSize) async throws -> any SSHPTYChannel {
        let pty = try backend.openPTY(cols: size.cols, rows: size.rows, termType: "xterm-256color", onExit: {}, onError: nil)
        return OpenSSHPTYAdapter(pty: pty, backend: backend)
    }

    func execute(_ command: String) async throws -> SSHCommandResult {
        let output = try await backend.executeCommand(command)
        return SSHCommandResult(output: output, exitCode: 0)
    }

    func openSFTP() async throws -> any SFTPChannel {
        let client = backend.makeSFTPClient()
        return OpenSSHSFTPAdapter(client: client)
    }

    func close() async { backend.close() }
}

// MARK: - Adapters (reuse PTYSessionChannelAdapter pattern)

private final class OpenSSHPTYAdapter: SSHPTYChannel, @unchecked Sendable {
    private let pty: PTYSession
    private let backend: OpenSSHBackend
    init(pty: PTYSession, backend: OpenSSHBackend) { self.pty = pty; self.backend = backend }
    var output: AsyncStream<String> { pty.makeRawOutputStream() }
    func write(_ data: Data) async throws { try await pty.sendInput(Array(data)[...]) }
    func resize(cols: Int, rows: Int) async throws { try await pty.resize(cols: cols, rows: rows) }
    func close() async { pty.close(); backend.close() }
}

private final class OpenSSHSFTPAdapter: SFTPChannel {
    private let client: OpenSSHSFTPClient
    init(client: OpenSSHSFTPClient) { self.client = client }
    func close() async { client.close() }
}
#endif
