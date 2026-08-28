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
import os

final class NativeSSHSession: SSHSession, @unchecked Sendable {
    let client: SSHClient
    private let _endpoint: SSHEndpoint
    private let stateBox = NIOLockedValueBox<SSHSessionState>(.connected)
    /// 供 N×TCP 池复用认证与 HostKey（可选，兼容旧 init）
    private let pooledConfig: SSHConnectionConfig?
    private let pooledHostKeyStore: (any SSHHostKeyStore)?

    var endpoint: SSHEndpoint { _endpoint }
    var state: SSHSessionState { stateBox.withLockedValue { $0 } }

    init(client: SSHClient, endpoint: SSHEndpoint) {
        self.client = client
        self._endpoint = endpoint
        pooledConfig = nil
        pooledHostKeyStore = nil
    }

    init(client: SSHClient, endpoint: SSHEndpoint, config: SSHConnectionConfig, hostKeyStore: any SSHHostKeyStore) {
        self.client = client
        self._endpoint = endpoint
        pooledConfig = config
        pooledHostKeyStore = hostKeyStore
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
        if let cfg = pooledConfig, let store = pooledHostKeyStore {
            return CitadelSFTPChannel(sftp: sftp, pooledConfig: cfg, hostKeyStore: store)
        }
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
    private let pooledConfig: SSHConnectionConfig?
    private let pooledHostKeyStore: (any SSHHostKeyStore)?
    init(sftp: SFTPClient, pooledConfig: SSHConnectionConfig? = nil, hostKeyStore: (any SSHHostKeyStore)? = nil) {
        self.sftp = sftp
        self.pooledConfig = pooledConfig
        self.pooledHostKeyStore = hostKeyStore
    }

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
        // P2: >500MB 优先 N×TCP 真并行，其次多 Channel 单 TCP，再回退单流
        if SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
            // 1) N×TCP 池化（独立 SSH+TCP，突破单 TCP 拥塞）
            if let cfg = pooledConfig, let store = pooledHostKeyStore {
                let shards = SFTPParallelStrategy.shardCount(for: total)
                Log.sftp.info("[POOL] try N×TCP upload total=\(total) shards=\(shards)")
                do {
                    let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                    defer { Task { for handle in pool { await handle.close() } } }
                    try await SFTPParallelTransferEngine.parallelUploadMultiTCP(
                        handles: pool,
                        remotePath: remotePath,
                        localURL: localURL,
                        totalBytes: total,
                        isCancelled: { false },
                        onProgress: onProgress
                    )
                    if total == 0 { onProgress(1.0) }
                    return
                } catch is CancellationError {
                    throw SFTPServiceError.transferCancelled
                } catch let err as SFTPServiceError where err == .transferCancelled {
                    throw err
                } catch {
                    Log.sftp.warning("[POOL] N×TCP upload failed, fallback to multi-channel: \(String(describing: error))")
                }
            }
            // 2) 多 Channel 单 TCP
            Log.sftp.info("[P2] Native upload multi-channel total=\(total)")
            do {
                try await SFTPParallelTransferEngine.parallelUploadMultiChannel(
                    sftp: sftp,
                    remotePath: remotePath,
                    localURL: localURL,
                    totalBytes: total,
                    isCancelled: { false },
                    onProgress: onProgress
                )
                if total == 0 { onProgress(1.0) }
                return
            } catch is CancellationError {
                throw SFTPServiceError.transferCancelled
            } catch let err as SFTPServiceError where err == .transferCancelled {
                throw err
            } catch {
                Log.sftp.warning("[P2] multiChannel upload failed, fallback to single-handle parallel: \(String(describing: error))")
                // 回退：单 handle 并行
                let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                let remoteFile = SendableSFTPFile(file)
                do {
                    try await SFTPParallelTransferEngine.parallelUpload(
                        localURL: localURL,
                        remoteFile: remoteFile,
                        totalBytes: total,
                        isCancelled: { false },
                        onProgress: onProgress
                    )
                    try? await file.close()
                } catch {
                    Log.sftp.warning("[P2] single-handle parallel failed, fallback to single stream: \(String(describing: error))")
                    do {
                        try await singleStreamUpload(localURL: localURL, total: total, remoteFile: remoteFile, onProgress: onProgress)
                        try? await file.close()
                    } catch {
                        try? await file.close()
                        throw error
                    }
                }
                if total == 0 { onProgress(1.0) }
                return
            }
        }
        // 单流路径
        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        let remoteFile = SendableSFTPFile(file)
        do {
            try await singleStreamUpload(localURL: localURL, total: total, remoteFile: remoteFile, onProgress: onProgress)
            if total == 0 { onProgress(1.0) }
            try? await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    private func singleStreamUpload(localURL: URL, total: UInt64, remoteFile: SendableSFTPFile, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let reader = try SFTPTransferActor(url: localURL)
        defer { Task { await reader.close() } }
        let chunkSize = SFTPParallelStrategy.chunkSize
        let pipelineDepth: Int = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total)
        var offset: UInt64 = 0
        var completedBytes: UInt64 = 0
        var pending = 0
        var lastProgress: Double = -1
        var lastEmit = Date.distantPast
        let throttle: TimeInterval = 0.0 // 1:1
        try await withThrowingTaskGroup(of: Int.self) { group in
            while true {
                while pending < pipelineDepth {
                    let chunkData = try await reader.readChunk(offset: offset, length: chunkSize)
                    guard !chunkData.isEmpty else { break }
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
                let now = Date()
                if progress >= 1.0 || now.timeIntervalSince(lastEmit) >= throttle {
                    lastProgress = progress; lastEmit = now
                    onProgress(min(progress, 1.0))
                }
            }
            try await group.waitForAll()
        }
    }

    func download(_ remotePath: String, to localURL: URL, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let attrs = try? await sftp.getAttributes(at: remotePath)
        let total = attrs?.size ?? 0
        if total > 0, SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
            // 1) N×TCP 真并行
            if let cfg = pooledConfig, let store = pooledHostKeyStore {
                let shards = SFTPParallelStrategy.shardCount(for: total)
                Log.sftp.info("[POOL] try N×TCP download total=\(total) shards=\(shards)")
                do {
                    let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                    defer { Task { for handle in pool { await handle.close() } } }
                    try await SFTPParallelTransferEngine.parallelDownloadMultiTCP(
                        handles: pool,
                        remotePath: remotePath,
                        localURL: localURL,
                        totalBytes: total,
                        isCancelled: { false },
                        onProgress: onProgress
                    )
                    if total == 0 { onProgress(1.0) }
                    return
                } catch is CancellationError {
                    throw SFTPServiceError.transferCancelled
                } catch let err as SFTPServiceError where err == .transferCancelled {
                    throw err
                } catch {
                    Log.sftp.warning("[POOL] N×TCP download failed, fallback to multi-channel: \(String(describing: error))")
                }
            }
            // 2) 多 Channel 单 TCP
            Log.sftp.info("[P2] Native download multi-channel total=\(total)")
            do {
                try await SFTPParallelTransferEngine.parallelDownloadMultiChannel(
                    sftp: sftp,
                    remotePath: remotePath,
                    localURL: localURL,
                    totalBytes: total,
                    isCancelled: { false },
                    onProgress: onProgress
                )
                if total == 0 { onProgress(1.0) }
                return
            } catch is CancellationError {
                throw SFTPServiceError.transferCancelled
            } catch let err as SFTPServiceError where err == .transferCancelled {
                throw err
            } catch {
                Log.sftp.warning("[P2] multiChannel download failed, fallback to single-handle: \(String(describing: error))")
                let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
                let remoteFile = SendableSFTPFile(file)
                do {
                    try await SFTPParallelTransferEngine.parallelDownload(
                        remoteFile: remoteFile,
                        localURL: localURL,
                        totalBytes: total,
                        isCancelled: { false },
                        onProgress: onProgress
                    )
                    try? await file.close()
                } catch {
                    Log.sftp.warning("[P2] single-handle parallel failed, fallback to single stream: \(String(describing: error))")
                    do {
                        try await singleStreamDownload(total: total, remoteFile: remoteFile, localURL: localURL, onProgress: onProgress)
                        try? await file.close()
                    } catch {
                        try? await file.close()
                        throw error
                    }
                }
                if total == 0 { onProgress(1.0) }
                return
            }
        }
        // 单流
        let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
        let remoteFile = SendableSFTPFile(file)
        do {
            try await singleStreamDownload(total: total, remoteFile: remoteFile, localURL: localURL, onProgress: onProgress)
            try? await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    private func singleStreamDownload(total: UInt64, remoteFile: SendableSFTPFile, localURL: URL, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: localURL.path) else { return }
        defer { handle.closeFile() }
        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize)
        let pipelineDepth: Int = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total)
        var nextReadOffset: UInt64 = 0
        var nextWriteOffset: UInt64 = 0
        var pending: [UInt64: Data] = [:]
        var readDone = false
        var inFlight = 0
        var lastProgress: Double = -1
        var lastEmit = Date.distantPast
        let throttle: TimeInterval = 0.0 // 1:1
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
                    let b = bytes
                    try await Task.detached(priority: .userInitiated) { try handle.write(contentsOf: b) }.value
                    nextWriteOffset += UInt64(b.count)
                    // Unknown size: indeterminate ProgressView (total==0) — don't fake real %.
                    let progress: Double = total > 0 ? Double(nextWriteOffset) / Double(total) : (readDone ? 1.0 : Double(nextWriteOffset) / Double(nextWriteOffset + UInt64(chunkSize)))
                    let now2 = Date()
                    if progress >= 1.0 || now2.timeIntervalSince(lastEmit) >= throttle {
                        lastProgress = progress; lastEmit = now2
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
    }

    func fileExists(at path: String) async -> Bool {
        do { _ = try await sftp.getAttributes(at: path); return true } catch { return false }
    }

    func close() async { try? await sftp.close() }
}
#endif
