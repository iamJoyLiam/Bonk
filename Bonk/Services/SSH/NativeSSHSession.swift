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
        // Resume: resume if remote already has partial (single-stream)
        if let remoteAttrs = try? await sftp.getAttributes(at: remotePath), let remoteSize = remoteAttrs.size, remoteSize > 0, remoteSize < total {
            Log.sftp.info("[RESUME] upload resume \(remotePath) \(remoteSize)/\(total)")
            let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create])
            let remoteFile = SendableSFTPFile(file)
            defer { let rf = remoteFile; Task { [rf] in try? await rf.file.close() } }
            try await resumeSingleStreamUpload(localURL: localURL, total: total, resumeOffset: remoteSize, remoteFile: remoteFile, onProgress: onProgress)
            return
        } else if let remoteAttrs = try? await sftp.getAttributes(at: remotePath), let remoteSize = remoteAttrs.size, remoteSize == total, total > 0 {
            Log.sftp.info("[RESUME] upload already complete \(remotePath) \(total)")
            onProgress(1.0)
            return
        }
        // P2: >500MB 优先 N×TCP 真并行，其次多 Channel 单 TCP，再回退单流
        if SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
            // 1) N×TCP 池化（独立 SSH+TCP，突破单 TCP 拥塞）
            if let cfg = pooledConfig, let store = pooledHostKeyStore {
                let shards = SFTPParallelStrategy.shardCount(for: total)
                Log.sftp.info("[POOL] try N×TCP upload total=\(total) shards=\(shards)")
                do {
                    let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                    defer { let p = pool; Task { [p] in for handle in p { await handle.close() } } }
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
        defer { let r = reader; Task { [r] in await r.close() } }
        let chunkSize = SFTPParallelStrategy.chunkSize(for: total)
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
        // Resume: resume if local already has partial
        if let localAttrs = try? FileManager.default.attributesOfItem(atPath: localURL.path), let localSize = localAttrs[.size] as? UInt64, localSize > 0, localSize < total {
            Log.sftp.info("[RESUME] download resume \(localURL.lastPathComponent) \(localSize)/\(total)")
            let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
            let remoteFile = SendableSFTPFile(file)
            defer { let rf = remoteFile; Task { [rf] in try? await rf.file.close() } }
            try await resumeSingleStreamDownload(total: total, resumeOffset: localSize, remoteFile: remoteFile, localURL: localURL, onProgress: onProgress)
            return
        } else if let localAttrs = try? FileManager.default.attributesOfItem(atPath: localURL.path), let localSize = localAttrs[.size] as? UInt64, localSize == total, total > 0 {
            Log.sftp.info("[RESUME] download already complete \(localURL.lastPathComponent) \(total)")
            onProgress(1.0)
            return
        }
        if total > 0, SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
            // 1) N×TCP 真并行
            if let cfg = pooledConfig, let store = pooledHostKeyStore {
                let shards = SFTPParallelStrategy.shardCount(for: total)
                Log.sftp.info("[POOL] try N×TCP download total=\(total) shards=\(shards)")
                do {
                    let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                    defer { let p = pool; Task { [p] in for handle in p { await handle.close() } } }
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
        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize(for: total))
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
                    try handle.write(contentsOf: b)
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

    // MARK: - Resume helpers
    private func resumeSingleStreamUpload(localURL: URL, total: UInt64, resumeOffset: UInt64, remoteFile: SendableSFTPFile, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let reader = try SFTPTransferActor(url: localURL)
        defer { let r = reader; Task { [r] in await r.close() } }
        let chunkSize = SFTPParallelStrategy.chunkSize(for: total - resumeOffset)
        let pipelineDepth = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total - resumeOffset)
        var offset = resumeOffset
        var completed = resumeOffset
        onProgress(Double(resumeOffset)/Double(total))
        try await withThrowingTaskGroup(of: Int.self) { group in
            var pending = 0
            while offset < total {
                while pending < pipelineDepth && offset < total {
                    let remaining = total - offset
                    let len = Int(min(UInt64(chunkSize), remaining))
                    let data = try await reader.readChunk(offset: offset, length: len)
                    guard !data.isEmpty else { break }
                    let off = offset
                    offset += UInt64(data.count)
                    pending += 1
                    group.addTask { try await SFTPTransferEngine.writeChunk(remoteFile, data: data, at: off) }
                }
                if pending == 0 { break }
                guard let written = try await group.next() else { break }
                pending -= 1
                completed += UInt64(written)
                onProgress(min(Double(completed)/Double(total), 1.0))
            }
            try await group.waitForAll()
        }
    }

    private func resumeSingleStreamDownload(total: UInt64, resumeOffset: UInt64, remoteFile: SendableSFTPFile, localURL: URL, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        guard let handle = FileHandle(forWritingAtPath: localURL.path) else { return }
        defer { handle.closeFile() }
        try handle.seekToEnd()
        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize(for: total - resumeOffset))
        let depth = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total - resumeOffset)
        var nextRead = resumeOffset
        var nextWrite = resumeOffset
        var pending: [UInt64: Data] = [:]
        var readDone = false
        var inFlight = 0
        onProgress(Double(resumeOffset)/Double(total))
        try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
            while !readDone || inFlight > 0 {
                while !readDone && inFlight < depth {
                    if nextRead >= total { readDone = true; break }
                    let len = UInt32(min(UInt64(chunkSize), total - nextRead))
                    let off = nextRead
                    nextRead += UInt64(len)
                    inFlight += 1
                    group.addTask { try await SFTPTransferEngine.readChunk(remoteFile, offset: off, length: len) }
                }
                guard let (off, data) = try await group.next() else { break }
                inFlight -= 1
                if data.isEmpty || data.count < Int(chunkSize) { readDone = true }
                if !data.isEmpty { pending[off] = data }
                while let bytes = pending.removeValue(forKey: nextWrite) {
                    try handle.seek(toOffset: nextWrite)
                    try handle.write(contentsOf: bytes)
                    nextWrite += UInt64(bytes.count)
                    onProgress(min(Double(nextWrite)/Double(total), 1.0))
                    if nextWrite >= total { readDone = true }
                }
            }
            try await group.waitForAll()
        }
        onProgress(1.0)
    }

    func fileExists(at path: String) async -> Bool {
        do { _ = try await sftp.getAttributes(at: path); return true } catch { return false }
    }

    func close() async { try? await sftp.close() }
}
#endif