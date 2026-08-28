//
//  SFTPChannelAdapters.swift
//  Bonk
//
//  Adapters that make the three SFTP backends conform to the single
//  `SFTPChannel` seam. Part of #2 SFTP unification (Phase 2.1).
//  Citadel and OpenSSH adapters translate the existing clients; VNext
//  already uses SFTPChannel directly via Native/Compatibility sessions.
//  Parallel transfer is an internal strategy of each adapter, not a
//  service-level branch.
//

import Foundation
#if os(macOS)
import Citadel
import NIOCore
import NIOFoundationCompat
import os

// MARK: - Citadel Adapter

/// Wraps Citadel's `SFTPClient` to the unified `SFTPChannel` seam.
/// Reuses the parallel strategy already proven in `CitadelSFTPChannel`
/// (NativeSSHSession) but exposed here for the legacy `SFTPService` path
/// until `SFTPStore` fully owns the seam.
final class CitadelSFTPAdapter: SFTPChannel {
    private let sftp: SFTPClient
    private let pooledConfig: SSHConnectionConfig?
    private let pooledStore: (any SSHHostKeyStore)?

    init(sftp: SFTPClient, pooledConfig: SSHConnectionConfig? = nil, pooledStore: (any SSHHostKeyStore)? = nil) {
        self.sftp = sftp
        self.pooledConfig = pooledConfig
        self.pooledStore = pooledStore
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
        if isDirectory { try await sftp.rmdir(at: path) } else { try await sftp.remove(at: path) }
    }

    func upload(_ localURL: URL, to remotePath: String, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs[.size] as? UInt64) ?? 0
        if SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
            if let cfg = pooledConfig, let store = pooledStore {
                let shards = SFTPParallelStrategy.shardCount(for: total)
                Log.sftp.info("[POOL] try N×TCP upload total=\(total) shards=\(shards)")
                do {
                    let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                    defer { Task { for h in pool { await h.close() } } }
                    try await SFTPParallelTransferEngine.parallelUploadMultiTCP(
                        handles: pool, remotePath: remotePath, localURL: localURL,
                        totalBytes: total, isCancelled: { false }, onProgress: onProgress
                    )
                    if total == 0 { onProgress(1.0) }
                    return
                } catch {
                    Log.sftp.warning("[POOL] N×TCP upload failed, fallback: \(error)")
                }
            }
            Log.sftp.info("[P2] Citadel upload multi-channel total=\(total)")
            do {
                try await SFTPParallelTransferEngine.parallelUploadMultiChannel(
                    sftp: sftp, remotePath: remotePath, localURL: localURL,
                    totalBytes: total, isCancelled: { false }, onProgress: onProgress
                )
                if total == 0 { onProgress(1.0) }
                return
            } catch {
                Log.sftp.warning("[P2] multiChannel upload failed, fallback: \(error)")
                let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                let remoteFile = SendableSFTPFile(file)
                do {
                    try await SFTPParallelTransferEngine.parallelUpload(
                        localURL: localURL, remoteFile: remoteFile,
                        totalBytes: total, isCancelled: { false }, onProgress: onProgress
                    )
                    try? await file.close()
                } catch {
                    Log.sftp.warning("[P2] single-handle parallel failed, fallback: \(error)")
                    try await singleStreamUpload(localURL: localURL, total: total, remoteFile: remoteFile, onProgress: onProgress)
                    try? await file.close()
                }
                if total == 0 { onProgress(1.0) }
                return
            }
        }
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
        let pipelineDepth = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total)
        var offset: UInt64 = 0
        var completed: UInt64 = 0
        var pending = 0
        var last: Double = -1
        var lastEmit = Date.distantPast
        let throttle: TimeInterval = 0.0 // 1:1
        try await withThrowingTaskGroup(of: Int.self) { group in
            while true {
                while pending < pipelineDepth {
                    let data = try await reader.readChunk(offset: offset, length: chunkSize)
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
                let p = total > 0 ? Double(completed) / Double(total) : 1.0
                let now = Date()
                // OR: 1% visible OR 50ms time — never drop visible jumps
                if p >= 1.0 || now.timeIntervalSince(lastEmit) >= throttle { last = p; lastEmit = now; onProgress(min(p, 1.0)) }
            }
            try await group.waitForAll()
        }
    }

    func download(_ remotePath: String, to localURL: URL, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let attrs = try? await sftp.getAttributes(at: remotePath)
        let total = attrs?.size ?? 0
        Log.sftp.debug("[ADAPTER] download \(remotePath, privacy: .public) total=\(total)")
        if total > 0, SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
            if let cfg = pooledConfig, let store = pooledStore {
                let shards = SFTPParallelStrategy.shardCount(for: total)
                Log.sftp.info("[POOL] try N×TCP download total=\(total) shards=\(shards)")
                do {
                    let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                    defer { Task { for h in pool { await h.close() } } }
                    try await SFTPParallelTransferEngine.parallelDownloadMultiTCP(
                        handles: pool, remotePath: remotePath, localURL: localURL,
                        totalBytes: total, isCancelled: { false }, onProgress: onProgress
                    )
                    if total == 0 { onProgress(1.0) }
                    return
                } catch {
                    Log.sftp.warning("[POOL] N×TCP download failed, fallback: \(error)")
                }
            }
            Log.sftp.info("[P2] Citadel download multi-channel total=\(total)")
            do {
                try await SFTPParallelTransferEngine.parallelDownloadMultiChannel(
                    sftp: sftp, remotePath: remotePath, localURL: localURL,
                    totalBytes: total, isCancelled: { false }, onProgress: onProgress
                )
                if total == 0 { onProgress(1.0) }
                return
            } catch {
                Log.sftp.warning("[P2] multiChannel download failed, fallback: \(error)")
                let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
                let remoteFile = SendableSFTPFile(file)
                do {
                    try await SFTPParallelTransferEngine.parallelDownload(
                        remoteFile: remoteFile, localURL: localURL,
                        totalBytes: total, isCancelled: { false }, onProgress: onProgress
                    )
                    try? await file.close()
                } catch {
                    Log.sftp.warning("[P2] single-handle parallel failed, fallback: \(error)")
                    try await singleStreamDownload(total: total, remoteFile: remoteFile, localURL: localURL, onProgress: onProgress)
                    try? await file.close()
                }
                if total == 0 { onProgress(1.0) }
                return
            }
        }
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
        // singleStreamDownload total=\(total) — verbose, keep debug only on failure
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: localURL.path) else { return }
        defer { handle.closeFile() }
        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize)
        let depth = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total)
        var nextRead: UInt64 = 0
        var nextWrite: UInt64 = 0
        var pending: [UInt64: Data] = [:]
        var readDone = false
        var inFlight = 0
        var last: Double = -1
        var lastEmit = Date.distantPast
        let throttle: TimeInterval = 0.0 // 1:1
        try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
            while !readDone || inFlight > 0 {
                while !readDone && inFlight < depth {
                    let off = nextRead
                    nextRead += UInt64(chunkSize)
                    inFlight += 1
                    group.addTask { try await SFTPTransferEngine.readChunk(remoteFile, offset: off, length: chunkSize) }
                }
                guard let (off, data) = try await group.next() else { break }
                inFlight -= 1
                if data.isEmpty || data.count < Int(chunkSize) { readDone = true }
                if !data.isEmpty { pending[off] = data }
                while let bytes = pending.removeValue(forKey: nextWrite) {
                    try await Task.detached(priority: .userInitiated) { try handle.write(contentsOf: bytes) }.value
                    nextWrite += UInt64(bytes.count)
                    // Unknown size: don't synthesize "real" percentage — SFTPService/SFTPWindowView
                    // now shows indeterminate ProgressView for total==0. Keep internal p monotonic for
                    // completion detection but never display as %.
                    let p: Double = total > 0 ? Double(nextWrite) / Double(total) : (readDone ? 1.0 : Double(nextWrite) / Double(nextWrite + UInt64(chunkSize)))
                    let now2 = Date()
                    if p >= 1.0 || now2.timeIntervalSince(lastEmit) >= throttle { last = p; lastEmit = now2; onProgress(min(p, 1.0)) }
                }
            }
            try await group.waitForAll()
        }
        if total == 0 { onProgress(1.0) }
        if last < 1.0 { onProgress(1.0) }
    }

    func fileExists(at path: String) async -> Bool {
        do { _ = try await sftp.getAttributes(at: path); return true } catch { return false }
    }

    func close() async { try? await sftp.close() }
}

// MARK: - OpenSSH Adapter (SFTPService seam, distinct from CompatibilitySSHSession.OpenSSHSFTPAdapter)

final class OpenSSHSFTPChannelAdapter: SFTPChannel {
    private let client: OpenSSHSFTPClient
    init(client: OpenSSHSFTPClient) { self.client = client }
    func realPath() async throws -> String { try await client.realPath() }
    func listDirectory(at path: String) async throws -> [SFTPFileEntry] { try await client.listDirectory(at: path) }
    func createDirectory(at path: String) async throws { try await client.createDirectory(at: path) }
    func remove(at path: String, isDirectory: Bool) async throws { try await client.remove(at: path, isDirectory: isDirectory) }
    func upload(_ localURL: URL, to remotePath: String, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.upload(localURL, to: remotePath, operationID: operationID, onProgress: onProgress)
    }
    func download(_ remotePath: String, to localURL: URL, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.download(remotePath, to: localURL, operationID: operationID, onProgress: onProgress)
    }
    func fileExists(at path: String) async -> Bool { await client.fileExists(at: path) }
    func close() async { client.close() }
}
#endif
