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
        // Atomic: upload to .bonk.part, verify, then rename
        let tempRemotePath = remotePath + ".bonk.part"
        try? await sftp.remove(at: tempRemotePath)
        do {
            if SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
                if let cfg = pooledConfig, let store = pooledStore {
                    let shards = SFTPParallelStrategy.shardCount(for: total)
                    Log.sftp.info("[POOL] try N×TCP upload total=\(total) shards=\(shards)")
                    do {
                        let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                        defer { let profile = pool; Task { [profile] in for handle in profile { await handle.close() } } }
                        try await SFTPParallelTransferEngine.parallelUploadMultiTCP(
                            handles: pool, remotePath: tempRemotePath, localURL: localURL,
                            totalBytes: total, isCancelled: { false }, onProgress: onProgress
                        )
                        try await verifyAndRenameRemote(tempPath: tempRemotePath, finalPath: remotePath, expectedBytes: total, sftp: sftp)
                        if total == 0 { onProgress(1.0) }
                        return
                    } catch {
                        Log.sftp.warning("[POOL] N×TCP upload failed, fallback: \(error)")
                        try? await sftp.remove(at: tempRemotePath)
                    }
                }
                Log.sftp.info("[P2] Citadel upload multi-channel total=\(total)")
                do {
                    try await SFTPParallelTransferEngine.parallelUploadMultiChannel(
                        sftp: sftp, remotePath: tempRemotePath, localURL: localURL,
                        totalBytes: total, isCancelled: { false }, onProgress: onProgress
                    )
                    try await verifyAndRenameRemote(tempPath: tempRemotePath, finalPath: remotePath, expectedBytes: total, sftp: sftp)
                    if total == 0 { onProgress(1.0) }
                    return
                } catch {
                    Log.sftp.warning("[P2] multiChannel upload failed, fallback: \(error)")
                    try? await sftp.remove(at: tempRemotePath)
                    let file = try await sftp.openFile(filePath: tempRemotePath, flags: [.write, .create, .truncate])
                    let remoteFile = SendableSFTPFile(file)
                    do {
                        try await SFTPParallelTransferEngine.parallelUpload(
                            localURL: localURL, remoteFile: remoteFile,
                            totalBytes: total, isCancelled: { false }, onProgress: onProgress
                        )
                        try? await file.close()
                        try await verifyAndRenameRemote(tempPath: tempRemotePath, finalPath: remotePath, expectedBytes: total, sftp: sftp)
                    } catch {
                        Log.sftp.warning("[P2] single-handle parallel failed, fallback: \(error)")
                        try? await sftp.remove(at: tempRemotePath)
                        try await singleStreamUpload(localURL: localURL, total: total, remoteFile: remoteFile, onProgress: onProgress)
                        try? await file.close()
                        try await verifyAndRenameRemote(tempPath: tempRemotePath, finalPath: remotePath, expectedBytes: total, sftp: sftp)
                    }
                    if total == 0 { onProgress(1.0) }
                    return
                }
            }
            let file = try await sftp.openFile(filePath: tempRemotePath, flags: [.write, .create, .truncate])
            let remoteFile = SendableSFTPFile(file)
            do {
                try await singleStreamUpload(localURL: localURL, total: total, remoteFile: remoteFile, onProgress: onProgress)
                if total == 0 { onProgress(1.0) }
                try? await file.close()
                try await verifyAndRenameRemote(tempPath: tempRemotePath, finalPath: remotePath, expectedBytes: total, sftp: sftp)
            } catch {
                try? await file.close()
                try? await sftp.remove(at: tempRemotePath)
                throw error
            }
        } catch {
            try? await sftp.remove(at: tempRemotePath)
            throw error
        }
    }

    private func verifyAndRenameRemote(tempPath: String, finalPath: String, expectedBytes: UInt64, sftp: SFTPClient) async throws {
        if expectedBytes > 0 {
            let attrs = try await sftp.getAttributes(at: tempPath)
            guard let size = attrs.size, size == expectedBytes else {
                let got = attrs.size ?? 0
                try? await sftp.remove(at: tempPath)
                throw SFTPServiceError.operationFailed("Upload incomplete: expected \(expectedBytes) got \(got)")
            }
        }
        try await sftp.rename(at: tempPath, to: finalPath, flags: 0)
    }

    private func singleStreamUpload(localURL: URL, total: UInt64, remoteFile: SendableSFTPFile, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let reader = try SFTPTransferActor(url: localURL)
        defer { let row = reader; Task { [row] in await row.close() } }
        let chunkSize = SFTPParallelStrategy.chunkSize(for: total)
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
                let profile = total > 0 ? Double(completed) / Double(total) : 1.0
                let now = Date()
                // OR: 1% visible OR 50ms time — never drop visible jumps
                if profile >= 1.0 || now.timeIntervalSince(lastEmit) >= throttle { last = profile; lastEmit = now; onProgress(min(profile, 1.0)) }
            }
            try await group.waitForAll()
        }
    }

    func download(_ remotePath: String, to localURL: URL, operationID: UUID, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let attrs = try? await sftp.getAttributes(at: remotePath)
        let total = attrs?.size ?? 0
        Log.sftp.debug("[ADAPTER] download \(remotePath, privacy: .public) total=\(total)")
        // Atomic: temp file -> verify -> move
        let tempURL = URL(fileURLWithPath: localURL.path + ".bonk.part")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            if total > 0, SFTPParallelStrategy.shouldUseParallel(totalBytes: total) {
                if let cfg = pooledConfig, let store = pooledStore {
                    let shards = SFTPParallelStrategy.shardCount(for: total)
                    Log.sftp.info("[POOL] try N×TCP download total=\(total) shards=\(shards)")
                    do {
                        let pool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: shards)
                        defer { let profile = pool; Task { [profile] in for handle in profile { await handle.close() } } }
                        try await SFTPParallelTransferEngine.parallelDownloadMultiTCP(
                            handles: pool, remotePath: remotePath, localURL: tempURL,
                            totalBytes: total, isCancelled: { false }, onProgress: onProgress
                        )
                        try await verifyAndMove(tempURL: tempURL, finalURL: localURL, expectedBytes: total)
                        if total == 0 { onProgress(1.0) }
                        return
                    } catch {
                        Log.sftp.warning("[POOL] N×TCP download failed, fallback: \(error)")
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                }
                Log.sftp.info("[P2] Citadel download multi-channel total=\(total)")
                do {
                    try await SFTPParallelTransferEngine.parallelDownloadMultiChannel(
                        sftp: sftp, remotePath: remotePath, localURL: tempURL,
                        totalBytes: total, isCancelled: { false }, onProgress: onProgress
                    )
                    try await verifyAndMove(tempURL: tempURL, finalURL: localURL, expectedBytes: total)
                    if total == 0 { onProgress(1.0) }
                    return
                } catch {
                    Log.sftp.warning("[P2] multiChannel download failed, fallback: \(error)")
                    try? FileManager.default.removeItem(at: tempURL)
                    let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
                    let remoteFile = SendableSFTPFile(file)
                    do {
                        try await SFTPParallelTransferEngine.parallelDownload(
                            remoteFile: remoteFile, localURL: tempURL,
                            totalBytes: total, isCancelled: { false }, onProgress: onProgress
                        )
                        try? await file.close()
                        try await verifyAndMove(tempURL: tempURL, finalURL: localURL, expectedBytes: total)
                    } catch {
                        Log.sftp.warning("[P2] single-handle parallel failed, fallback: \(error)")
                        try? FileManager.default.removeItem(at: tempURL)
                        try await singleStreamDownload(total: total, remoteFile: remoteFile, localURL: tempURL, onProgress: onProgress)
                        try? await file.close()
                        try await verifyAndMove(tempURL: tempURL, finalURL: localURL, expectedBytes: total)
                    }
                    if total == 0 { onProgress(1.0) }
                    return
                }
            }
            let file = try await sftp.openFile(filePath: remotePath, flags: [.read])
            let remoteFile = SendableSFTPFile(file)
            do {
                try await singleStreamDownload(total: total, remoteFile: remoteFile, localURL: tempURL, onProgress: onProgress)
                try? await file.close()
                try await verifyAndMove(tempURL: tempURL, finalURL: localURL, expectedBytes: total)
            } catch {
                try? await file.close()
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func verifyAndMove(tempURL: URL, finalURL: URL, expectedBytes: UInt64) async throws {
        if expectedBytes > 0 {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
                  let size = attrs[.size] as? UInt64 else {
                throw SFTPServiceError.operationFailed("Download verification failed: cannot stat temp file")
            }
            guard size == expectedBytes else {
                throw SFTPServiceError.operationFailed("Download incomplete: expected \(expectedBytes) got \(size)")
            }
            // fsync
            if let fhValue = FileHandle(forReadingAtPath: tempURL.path) {
                try? fhValue.synchronizeFile()
                fhValue.closeFile()
            }
            // Darwin fsync
            let fdValue = Darwin.open(tempURL.path, O_RDONLY)
            if fdValue >= 0 { _ = Darwin.fsync(fdValue); Darwin.close(fdValue) }
        } else {
            // Unknown size fsync
            if let fhValue = FileHandle(forReadingAtPath: tempURL.path) { try? fhValue.synchronizeFile(); fhValue.closeFile() }
        }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }

    private func singleStreamDownload(total: UInt64, remoteFile: SendableSFTPFile, localURL: URL, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: localURL.path) else {
            throw SFTPServiceError.operationFailed("Cannot open local file for writing: \(localURL.path)")
        }
        defer { handle.closeFile() }
        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize(for: total))
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
                    try handle.write(contentsOf: bytes)
                    nextWrite += UInt64(bytes.count)
                    // Unknown size: don't synthesize "real" percentage — SFTPService/SFTPWindowView
                    // now shows indeterminate ProgressView for total==0. Keep internal profile monotonic for
                    // completion detection but never display as %.
                    let profile: Double = total > 0 ? Double(nextWrite) / Double(total) : (readDone ? 1.0 : Double(nextWrite) / Double(nextWrite + UInt64(chunkSize)))
                    let now2 = Date()
                    if profile >= 1.0 || now2.timeIntervalSince(lastEmit) >= throttle { last = profile; lastEmit = now2; onProgress(min(profile, 1.0)) }
                }
            }
            try await group.waitForAll()
        }
        if total == 0 { onProgress(1.0) } else if last < 1.0, nextWrite == total { onProgress(1.0) }
        if total > 0, nextWrite != total {
            throw SFTPServiceError.operationFailed("Download incomplete singleStream: expected \(total) got \(nextWrite)")
        }
    }

    // MARK: - Resume helpers (legacy)
    private func resumeSingleStreamUpload(localURL: URL, total: UInt64, resumeOffset: UInt64, remoteFile: SendableSFTPFile, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let reader = try SFTPTransferActor(url: localURL)
        defer { let row = reader; Task { [row] in await row.close() } }
        let chunkSize = SFTPParallelStrategy.chunkSize(for: total - resumeOffset)
        let pipelineDepth = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total - resumeOffset)
        var offset = resumeOffset
        var completed = resumeOffset
        var pending = 0
        // Completed progress
        onProgress(Double(resumeOffset) / Double(total))
        try await withThrowingTaskGroup(of: Int.self) { group in
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
                let profile = Double(completed) / Double(total)
                onProgress(min(profile, 1.0))
            }
            try await group.waitForAll()
        }
    }

    private func resumeSingleStreamDownload(total: UInt64, resumeOffset: UInt64, remoteFile: SendableSFTPFile, localURL: URL, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        guard let handle = FileHandle(forWritingAtPath: localURL.path) else { return }
        defer { handle.closeFile() }
        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize(for: total - resumeOffset))
        let depth = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: total - resumeOffset)
        var nextRead = resumeOffset
        var nextWrite = resumeOffset
        var pending: [UInt64: Data] = [:]
        var readDone = false
        var inFlight = 0
        // Completed progress
        onProgress(Double(resumeOffset) / Double(total))
        try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
            while !readDone || inFlight > 0 {
                while !readDone && inFlight < depth {
                    let off = nextRead
                    if off >= total { readDone = true; break }
                    let remaining = total - off
                    let len = UInt32(min(UInt64(chunkSize), remaining))
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
                    let profile = Double(nextWrite) / Double(total)
                    onProgress(min(profile, 1.0))
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
