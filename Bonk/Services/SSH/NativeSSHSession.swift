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
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs[.size] as? UInt64) ?? 0
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        // Pipelined upload: 32KB * 16 = 512KB window, matches SFTPService Citadel path
        let chunkSize = 32_000
        let pipelineDepth = 32
        var offset: UInt64 = 0
        var completedBytes: UInt64 = 0
        var pending = 0
        var lastProgress: Double = -1
        let remoteFile = SendableSFTPFile(file)
        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                while true {
                    while pending < pipelineDepth {
                        guard let chunkData = try handle.read(upToCount: chunkSize), !chunkData.isEmpty else { break }
                        let chunkOffset = offset
                        offset += UInt64(chunkData.count)
                        pending += 1
                        group.addTask {
                            try await SFTPTransferEngine.writeChunk(remoteFile, data: chunkData, at: chunkOffset)
                        }
                    }
                    if pending == 0 { break }
                    guard let written = try await group.next() else { break }
                    pending -= 1
                    completedBytes += UInt64(written)
                    let progress = total > 0 ? Double(completedBytes) / Double(total) : 1.0
                    if progress - lastProgress >= 0.01 || progress >= 1.0 {
                        lastProgress = progress
                        onProgress(min(progress, 1.0))
                    }
                }
                try await group.waitForAll()
            }
            if total == 0 { onProgress(1.0) }
            try? await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func download(_ remotePath: String, to localURL: URL, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let attrs = try? await sftp.getAttributes(at: remotePath)
        let total = attrs?.size ?? 0
        let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: localURL.path) else {
            try? await file.close()
            return
        }
        defer { handle.closeFile() }
        // Pipelined download: 32KB * 16 = 512KB window
        let chunkSize: UInt32 = 32_000
        let pipelineDepth = 32
        var nextReadOffset: UInt64 = 0
        var nextWriteOffset: UInt64 = 0
        var pending: [UInt64: Data] = [:]
        var readDone = false
        var inFlight = 0
        var lastProgress: Double = -1
        let remoteFile = SendableSFTPFile(file)
        do {
            try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
                while !readDone || inFlight > 0 {
                    while !readDone && inFlight < pipelineDepth {
                        let readOffset = nextReadOffset
                        nextReadOffset += UInt64(chunkSize)
                        inFlight += 1
                        group.addTask {
                            try await SFTPTransferEngine.readChunk(remoteFile, offset: readOffset, length: chunkSize)
                        }
                    }
                    guard let (readOffset, data) = try await group.next() else { break }
                    inFlight -= 1
                    if data.isEmpty || data.count < Int(chunkSize) {
                        readDone = true
                    }
                    if !data.isEmpty {
                        pending[readOffset] = data
                    }
                    while let bytes = pending.removeValue(forKey: nextWriteOffset) {
                        try handle.write(contentsOf: bytes)
                        nextWriteOffset += UInt64(bytes.count)
                        let progress: Double = total > 0 ? Double(nextWriteOffset) / Double(total) : (readDone ? 1.0 : Double(nextWriteOffset) / Double(nextWriteOffset + UInt64(chunkSize)))
                        if progress - lastProgress >= 0.01 || progress >= 1.0 {
                            lastProgress = progress
                            onProgress(min(progress, 1.0))
                        }
                    }
                }
                try await group.waitForAll()
            }
            if total == 0 { onProgress(1.0) }
            if lastProgress < 1.0 {
                onProgress(1.0)
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
