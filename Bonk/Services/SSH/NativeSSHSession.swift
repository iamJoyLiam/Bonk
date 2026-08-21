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
    let client: SSHClient
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

    func realPath() async throws -> String {
        try await sftp.getRealPath(atPath: ".")
    }

    func listDirectory(at path: String) async throws -> [SFTPFileEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        var result: [SFTPFileEntry] = []
        for name in names {
            for component in name.components {
                if component.filename == "." || component.filename == ".." { continue }
                let isDir = component.longname.hasPrefix("d")
                let fullPath = (path as NSString).appendingPathComponent(component.filename)
                result.append(SFTPFileEntry(
                    id: fullPath, name: component.filename, path: fullPath,
                    isDirectory: isDir, size: component.attributes.size ?? 0,
                    permissions: component.attributes.permissions ?? 0,
                    modifiedAt: component.attributes.accessModificationTime?.modificationTime,
                    longname: component.longname
                ))
            }
        }
        result.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return result
    }

    func createDirectory(at path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    func remove(at path: String, isDirectory: Bool) async throws {
        if isDirectory {
            try await sftp.rmdir(at: path)
        } else {
            try await sftp.remove(at: path)
        }
    }

    func upload(_ localURL: URL, to remotePath: String, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let data = try Data(contentsOf: localURL)
        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        do {
            try await file.write(buffer, at: 0)
            onProgress(1.0)
            try? await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func download(_ remotePath: String, to localURL: URL, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: localURL.path) else {
            try? await file.close()
            return
        }
        defer { handle.closeFile() }
        let chunkSize: UInt32 = 32_000
        var offset: UInt64 = 0
        do {
            while true {
                let buffer = try await file.read(from: offset, length: chunkSize)
                if buffer.readableBytes == 0 { break }
                let data = Data(buffer.readableBytesView)
                handle.write(data)
                offset += UInt64(data.count)
                onProgress(Double(offset) / Double(max(offset, 1)))
                if buffer.readableBytes < Int(chunkSize) { break }
            }
            try? await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func fileExists(at path: String) async -> Bool {
        do { _ = try await sftp.getAttributes(at: path); return true } catch { return false }
    }

    func close() async { try? await sftp.close() }
}
#endif
