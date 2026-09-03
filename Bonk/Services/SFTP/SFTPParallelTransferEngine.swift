//
//  SFTPParallelTransferEngine.swift
//  Bonk — P2 Parallel SFTP (Multi-Segment)
//
//  Optimal: shard parallel to break bottleneck
//  
//    • Threshold 500M single stream
//    • Enable sharding above 500M
//    • Reuse single TCP multi-write safe
//    • Future N×TCP only replace session
//    • Progress, cancel, fallback encapsulated

import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import os.log
#if canImport(Citadel)
import Citadel
#endif

// MARK: - Strategy

enum SFTPParallelStrategy {
    /// Single threshold
    static let parallelThreshold: UInt64 = 50 * 1024 * 1024
    /// Tune 1M + pipeline 128
    static let chunkSize: Int = 1024 * 1024
    /// Adaptive chunk: small files use small chunks for lower TTFB/memory, large files use large chunks for throughput
    static func chunkSize(for totalBytes: UInt64) -> Int {
        if totalBytes == 0 { return 256 * 1024 } // Unknown size, conservative
        if totalBytes < 5 * 1024 * 1024 { return 256 * 1024 }
        if totalBytes < 50 * 1024 * 1024 { return 512 * 1024 }
        return 1024 * 1024
    }

    /// Shard count by size
    static func shardCount(for totalBytes: UInt64) -> Int {
        if totalBytes <= parallelThreshold { return 1 }
        if totalBytes <= 200 * 1024 * 1024 { return 4 }
        if totalBytes <= 1024 * 1024 * 1024 { return 4 }
        if totalBytes <= 10 * 1024 * 1024 * 1024 { return 8 }
        return 8
    }

    static func shouldUseParallel(totalBytes: UInt64) -> Bool {
        totalBytes > parallelThreshold
    }

    /// Pipeline depth per shard
    /// 1M*128 single; 4*128 limit 64M
    static func pipelinePerShard(shards: Int, totalBytes: UInt64) -> Int {
        switch shards {
        case 1:
            if totalBytes > 100 * 1024 * 1024 { return 128 } // 128MB
            if totalBytes > 10 * 1024 * 1024 { return 64 }  // 64MB
            return 32 // 32MB
        case 4: return 128  // 4×128×64KB≈32MB ， 32MB
        case 8: return 64  // 8×64×64KB≈32MB
        default: return 64
        }
    }
}

// MARK: - Progress Merger (lock-free)

private final class ProgressMerger: @unchecked Sendable {
    private let lock = NIOLockedValueBox<UInt64>(0)
    private let total: UInt64
    private let onProgress: @Sendable (Double) -> Void
    private let lastReported = NIOLockedValueBox<Double>(-1)
    // Throttle: 50ms OR 1% delta (≈20 FPS but never drop visible jumps) — never drop 1.0
    private let lastEmit = NIOLockedValueBox<Date>(.distantPast)
    private let throttle: TimeInterval = 0.0 // 1:1 — no drop, display interpolates via SwiftUI animation
    private let delta: Double = 0.0

    init(total: UInt64, onProgress: @Sendable @escaping (Double) -> Void) {
        self.total = total
        self.onProgress = onProgress
    }

    func add(_ bytes: UInt64) {
        let completed = lock.withLockedValue { accumulated -> UInt64 in
            accumulated += bytes
            return accumulated
        }
        let progress = total > 0 ? Double(completed) / Double(total) : 1.0
        let profile = min(progress, 1.0)
        if profile < 1.0 {
            let now = Date()
            let shouldEmit: Bool = lastEmit.withLockedValue { last in
                let timeOk = now.timeIntervalSince(last) >= throttle
                if timeOk { last = now; return true }
                return false
            }
            if !shouldEmit { return }
        } else {
            // completion always emit
        }
        lastReported.withLockedValue { last in last = profile }
        onProgress(profile)
    }

    var completed: UInt64 { lock.withLockedValue { $0 } }
}

// MARK: - Engine

enum SFTPParallelTransferEngine {

    // MARK: Upload — parallel shards over single SFTP file (offset writes)

    /// Parallel upload
    static func parallelUpload(
        localURL: URL,
        remoteFile: SendableSFTPFile,
        totalBytes: UInt64,
        isCancelled: @Sendable @escaping () async -> Bool,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard totalBytes > 0 else {
            onProgress(1.0)
            return
        }
        let shards = SFTPParallelStrategy.shardCount(for: totalBytes)
        guard shards > 1 else {
            // fallback ，
            throw SFTPServiceError.operationFailed("parallelUpload called with single shard")
        }
        let shardSize = (totalBytes + UInt64(shards) - 1) / UInt64(shards) // ceil
        let merger = ProgressMerger(total: totalBytes, onProgress: onProgress)
        Log.sftp.info("[P2] parallelUpload total=\(totalBytes) shards=\(shards) shardSize=\(shardSize)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for shardIndex in 0..<shards {
                let start = UInt64(shardIndex) * shardSize
                guard start < totalBytes else { break }
                let end = min(start + shardSize, totalBytes)
                group.addTask {
                    try await uploadShard(
                        localURL: localURL,
                        remoteFile: remoteFile,
                        range: start..<end,
                        shards: shards,
                        merger: merger,
                        isCancelled: isCancelled
                    )
                }
            }
            try await group.waitForAll()
        }
        // Ensure 100%
        if merger.completed < totalBytes { onProgress(1.0) }
    }

    private static func uploadShard(
        localURL: URL,
        remoteFile: SendableSFTPFile,
        range: Range<UInt64>,
        shards: Int,
        merger: ProgressMerger,
        isCancelled: @Sendable () async -> Bool
    ) async throws {
        let pipeline = SFTPParallelStrategy.pipelinePerShard(shards: shards, totalBytes: range.upperBound - range.lowerBound + 1)
        // P0 DispatchIO：Per shard fd, zero-copy
        let reader = try SFTPDispatchReader(url: localURL)
        defer { reader.close() }

        var offset = range.lowerBound
        var pending = 0

        try await withThrowingTaskGroup(of: Int.self) { group in
            while offset < range.upperBound {
                if await isCancelled() { group.cancelAll(); throw SFTPServiceError.transferCancelled }
                if Task.isCancelled { group.cancelAll(); throw CancellationError() }

                // Fill pipeline — adaptive small chunks
                while pending < pipeline && offset < range.upperBound {
                    let remaining = range.upperBound - offset
                    let adaptiveChunk = SFTPParallelStrategy.chunkSize(for: range.upperBound - range.lowerBound)
                    let length = Int(min(UInt64(adaptiveChunk), remaining))
                    let buffer = try reader.readByteBuffer(offset: offset, length: length)
                    guard buffer.readableBytes > 0 else { break }
                    let chunkOffset = offset
                    offset += UInt64(buffer.readableBytes)
                    pending += 1
                    group.addTask {
                        try await SFTPTransferEngine.writeBuffer(remoteFile, buffer: buffer, at: chunkOffset)
                    }
                    if buffer.readableBytes < length { break }
                }
                if pending == 0 { break }
                guard let written = try await group.next() else { break }
                pending -= 1
                merger.add(UInt64(written))
            }
            // Drain remaining
            while let written = try await group.next() {
                pending -= 1
                merger.add(UInt64(written))
            }
            try await group.waitForAll()
        }
    }

    // MARK: Download — parallel shards (range reads + pwrite)

    static func parallelDownload(
        remoteFile: SendableSFTPFile,
        localURL: URL,
        totalBytes: UInt64,
        isCancelled: @Sendable @escaping () async -> Bool,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard totalBytes > 0 else {
            onProgress(1.0)
            return
        }
        let shards = SFTPParallelStrategy.shardCount(for: totalBytes)
        guard shards > 1 else {
            throw SFTPServiceError.operationFailed("parallelDownload called with single shard")
        }
        let shardSize = (totalBytes + UInt64(shards) - 1) / UInt64(shards)
        let merger = ProgressMerger(total: totalBytes, onProgress: onProgress)
        Log.sftp.info("[P2] parallelDownload total=\(totalBytes) shards=\(shards)")

        // Preallocate to avoid race
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        if let fileHandle = try? FileHandle(forWritingTo: localURL) {
            try? fileHandle.truncate(atOffset: totalBytes)
            try? fileHandle.close()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for shardIndex in 0..<shards {
                let start = UInt64(shardIndex) * shardSize
                guard start < totalBytes else { break }
                let end = min(start + shardSize, totalBytes)
                group.addTask {
                    try await downloadShard(
                        remoteFile: remoteFile,
                        localURL: localURL,
                        range: start..<end,
                        shards: shards,
                        merger: merger,
                        isCancelled: isCancelled
                    )
                }
            }
            try await group.waitForAll()
        }
        if merger.completed != totalBytes {
            throw SFTPServiceError.operationFailed("Download incomplete: expected \(totalBytes) got \(merger.completed)")
        }
    }

    private static func downloadShard(
        remoteFile: SendableSFTPFile,
        localURL: URL,
        range: Range<UInt64>,
        shards: Int,
        merger: ProgressMerger,
        isCancelled: @Sendable () async -> Bool
    ) async throws {
        // downloadShard range \(range.lowerBound)-\(range.upperBound) shards=\(shards) — verbose
        let pipeline = SFTPParallelStrategy.pipelinePerShard(shards: shards, totalBytes: range.upperBound - range.lowerBound)
        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize(for: range.upperBound - range.lowerBound))

        // Per shard pwrite no seek race
        let fileDescriptor = Darwin.open(localURL.path, O_RDWR)
        guard fileDescriptor >= 0 else {
            throw SFTPServiceError.operationFailed("Cannot open local file for writing: \(localURL.path)")
        }
        defer { Darwin.close(fileDescriptor) }

        var nextReadOffset = range.lowerBound
        var pending: [UInt64: Data] = [:]
        var nextWriteOffset = range.lowerBound
        var readDone = false
        var inFlight = 0

        try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
            while !readDone || inFlight > 0 {
                if await isCancelled() { group.cancelAll(); throw SFTPServiceError.transferCancelled }
                if Task.isCancelled { group.cancelAll(); throw CancellationError() }

                while !readDone && inFlight < pipeline {
                    // Mark done at shard end
                    if nextReadOffset >= range.upperBound {
                        readDone = true
                        break
                    }
                    let readOffset = nextReadOffset
                    let remaining = range.upperBound - readOffset
                    let length = UInt32(min(UInt64(chunkSize), remaining))
                    nextReadOffset += UInt64(length)
                    inFlight += 1
                    group.addTask {
                        try await SFTPTransferEngine.readChunk(remoteFile, offset: readOffset, length: length)
                    }
                    // Next loop ends if less than chunk
                }

                guard let (readOffset, data) = try await group.next() else { break }
                inFlight -= 1
                if data.isEmpty || UInt64(data.count) < UInt64(chunkSize) {
                    // shard  EOF shard
                    // Still need data
                    if data.isEmpty {
                        if readOffset >= range.upperBound - UInt64(chunkSize) {
                            readDone = true
                        }
                        continue
                    }
                }
                if !data.isEmpty {
                    pending[readOffset] = data
                }

                // Batch pwrite per 1M
                var batch = Data()
                var batchStart = nextWriteOffset
                var batchBytes: UInt64 = 0
                while let bytes = pending.removeValue(forKey: nextWriteOffset) {
                    batch.append(bytes)
                    batchBytes += UInt64(bytes.count)
                    nextWriteOffset += UInt64(bytes.count)
                    // Flush at 1M or end
                    if batchBytes >= 1024 * 1024 || nextWriteOffset >= range.upperBound || pending[ nextWriteOffset] == nil {
                        let written = batch.withUnsafeBytes { ptr -> Int in
                            guard let base = ptr.baseAddress else { return 0 }
                            return Darwin.pwrite(fileDescriptor, base, batch.count, off_t(batchStart))
                        }
                        if written < 0 {
                            throw SFTPServiceError.operationFailed("pwrite failed at \(batchStart): \(String(cString: strerror(errno)))")
                        }
                        merger.add(batchBytes)
                        batch = Data()
                        batchStart = nextWriteOffset
                        batchBytes = 0
                    }
                    if nextWriteOffset >= range.upperBound { readDone = true }
                }
                // Flush remaining
                if !batch.isEmpty {
                    let written = batch.withUnsafeBytes { ptr -> Int in
                        guard let base = ptr.baseAddress else { return 0 }
                        return Darwin.pwrite(fileDescriptor, base, batch.count, off_t(batchStart))
                    }
                    if written < 0 { throw SFTPServiceError.operationFailed("pwrite failed at \(batchStart)") }
                    merger.add(batchBytes)
                }
                // Wait if next not ready
            }
            // flush
            let sortedKeys = pending.keys.sorted()
            for key in sortedKeys {
                if let bytes = pending.removeValue(forKey: key) {
                    let written = bytes.withUnsafeBytes { ptr -> Int in
                        guard let base = ptr.baseAddress else { return 0 }
                        return Darwin.pwrite(fileDescriptor, base, bytes.count, off_t(key))
                    }
                    if written < 0 {
                        throw SFTPServiceError.operationFailed("pwrite failed at \(key): \(String(cString: strerror(errno)))")
                    }
                    merger.add(UInt64(bytes.count))
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Multi-Channel Upload (N SFTPFile, N Channel)

    /// Multi-channel per shard
    static func parallelUploadMultiChannel(
        sftp: Any?,
        remotePath: String,
        localURL: URL,
        totalBytes: UInt64,
        isCancelled: @Sendable @escaping () async -> Bool,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        #if canImport(Citadel)
        guard let client = sftp as? SFTPClient else {
            // Fallback single
            throw SFTPServiceError.operationFailed("SFTPClient unavailable for multi-channel")
        }
        let shards = SFTPParallelStrategy.shardCount(for: totalBytes)
        let shardSize = (totalBytes + UInt64(shards) - 1) / UInt64(shards)
        var files: [SendableSFTPFile] = []
        // Open sequentially
        for idx in 0..<shards {
            let file = try await client.openFile(
                filePath: remotePath,
                flags: idx == 0 ? [.write, .create, .truncate] : [.write, .create]
            )
            files.append(SendableSFTPFile(file))
        }
        defer {
            for file in files { Task { try? await file.file.close() } }
        }
        let merger = ProgressMerger(total: totalBytes, onProgress: onProgress)
        Log.sftp.info("[P2] multiChannel upload shards=\(shards) files=\(files.count)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in 0..<shards {
                let start = UInt64(idx) * shardSize
                guard start < totalBytes else { break }
                let end = min(start + shardSize, totalBytes)
                let remoteFile = files[idx]
                group.addTask {
                    try await uploadShard(
                        localURL: localURL,
                        remoteFile: remoteFile,
                        range: start..<end,
                        shards: shards,
                        merger: merger,
                        isCancelled: isCancelled
                    )
                }
            }
            try await group.waitForAll()
        }
        if merger.completed != totalBytes {
            throw SFTPServiceError.operationFailed("Upload incomplete: expected \(totalBytes) got \(merger.completed)")
        }
        #else
        throw SFTPServiceError.operationFailed("Citadel unavailable")
        #endif
    }

    // MARK: - Multi-Channel Download

    static func parallelDownloadMultiChannel(
        sftp: Any?,
        remotePath: String,
        localURL: URL,
        totalBytes: UInt64,
        isCancelled: @Sendable @escaping () async -> Bool,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        #if canImport(Citadel)
        guard let client = sftp as? SFTPClient else {
            throw SFTPServiceError.operationFailed("SFTPClient unavailable for multi-channel")
        }
        let shards = SFTPParallelStrategy.shardCount(for: totalBytes)
        let shardSize = (totalBytes + UInt64(shards) - 1) / UInt64(shards)
        var files: [SendableSFTPFile] = []
        for _ in 0..<shards {
            let file = try await client.openFile(filePath: remotePath, flags: [.read])
            files.append(SendableSFTPFile(file))
        }
        defer {
            for file in files { Task { try? await file.file.close() } }
        }
        // Preallocate
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        if let fileHandle = try? FileHandle(forWritingTo: localURL) {
            try? fileHandle.truncate(atOffset: totalBytes)
            try? fileHandle.close()
        }
        let merger = ProgressMerger(total: totalBytes, onProgress: onProgress)
        Log.sftp.info("[P2] multiChannel download shards=\(shards)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in 0..<shards {
                let start = UInt64(idx) * shardSize
                guard start < totalBytes else { break }
                let end = min(start + shardSize, totalBytes)
                let remoteFile = files[idx]
                group.addTask {
                    try await downloadShard(
                        remoteFile: remoteFile,
                        localURL: localURL,
                        range: start..<end,
                        shards: shards,
                        merger: merger,
                        isCancelled: isCancelled
                    )
                }
            }
            try await group.waitForAll()
        }
        if merger.completed != totalBytes {
            throw SFTPServiceError.operationFailed("Download incomplete: expected \(totalBytes) got \(merger.completed)")
        }
        #else
        throw SFTPServiceError.operationFailed("Citadel unavailable")
        #endif
    }

    // MARK: - N×TCP  SSHClient +  SFTPClient

    #if os(macOS)
    static func parallelUploadMultiTCP(
        handles: [PooledSFTPHandle],
        remotePath: String,
        localURL: URL,
        totalBytes: UInt64,
        isCancelled: @Sendable @escaping () async -> Bool,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let shards = handles.count
        let shardSize = (totalBytes + UInt64(shards) - 1) / UInt64(shards)
        // handle ， truncate
        var files: [SendableSFTPFile] = []
        for (idx, handle) in handles.enumerated() {
            let file = try await handle.sftpClient.openFile(
                filePath: remotePath,
                flags: idx == 0 ? [.write, .create, .truncate] : [.write, .create]
            )
            files.append(SendableSFTPFile(file))
        }
        defer {
            for file in files { Task { try? await file.file.close() } }
        }
        let merger = ProgressMerger(total: totalBytes, onProgress: onProgress)
        Log.sftp.info("[POOL] multiTCP upload shards=\(shards) handles=\(handles.count)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in 0..<shards {
                let start = UInt64(idx) * shardSize
                guard start < totalBytes else { break }
                let end = min(start + shardSize, totalBytes)
                let remoteFile = files[idx]
                group.addTask {
                    try await uploadShard(
                        localURL: localURL,
                        remoteFile: remoteFile,
                        range: start..<end,
                        shards: shards,
                        merger: merger,
                        isCancelled: isCancelled
                    )
                }
            }
            try await group.waitForAll()
        }
        if merger.completed != totalBytes {
            throw SFTPServiceError.operationFailed("Upload incomplete: expected \(totalBytes) got \(merger.completed)")
        }
    }

    static func parallelDownloadMultiTCP(
        handles: [PooledSFTPHandle],
        remotePath: String,
        localURL: URL,
        totalBytes: UInt64,
        isCancelled: @Sendable @escaping () async -> Bool,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let shards = handles.count
        let shardSize = (totalBytes + UInt64(shards) - 1) / UInt64(shards)
        var files: [SendableSFTPFile] = []
        for handle in handles {
            let file = try await handle.sftpClient.openFile(filePath: remotePath, flags: [.read])
            files.append(SendableSFTPFile(file))
        }
        defer {
            for file in files { Task { try? await file.file.close() } }
        }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        if let fileHandle = try? FileHandle(forWritingTo: localURL) {
            try? fileHandle.truncate(atOffset: totalBytes)
            try? fileHandle.close()
        }
        let merger = ProgressMerger(total: totalBytes, onProgress: onProgress)
        Log.sftp.info("[POOL] multiTCP download shards=\(shards) total=\(totalBytes)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in 0..<shards {
                let start = UInt64(idx) * shardSize
                guard start < totalBytes else { break }
                let end = min(start + shardSize, totalBytes)
                let remoteFile = files[idx]
                group.addTask {
                    try await downloadShard(
                        remoteFile: remoteFile,
                        localURL: localURL,
                        range: start..<end,
                        shards: shards,
                        merger: merger,
                        isCancelled: isCancelled
                    )
                }
            }
            try await group.waitForAll()
        }
        if merger.completed != totalBytes {
            throw SFTPServiceError.operationFailed("Download incomplete: expected \(totalBytes) got \(merger.completed)")
        }
    }
    #endif
}
