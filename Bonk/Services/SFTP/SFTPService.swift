//
//  SFTPService.swift
//  Bonk
//

@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import os.log

/// High-level SFTP operations with OpenSSH and Citadel backends.
@Observable
@MainActor
final class SFTPService {
    var currentPath: String = "/"
    var entries: [SFTPFileEntry] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var transfers: [SFTPTransfer] = []

    private var sftpClient: SFTPClient?
    #if os(macOS)
        private var openSSHSFTPClient: OpenSSHSFTPClient?
    #endif
    private var vnextChannel: (any SFTPChannel)?
    /// Monotonic counter for listDirectory: a stale result (background
    /// refresh finishing after the user navigated) must not overwrite the
    /// newer listing.
    private var listRequestSequence = 0

    /// Claim the next list request id.
    private func beginListRequest() -> Int {
        listRequestSequence += 1
        return listRequestSequence
    }

    init() {}

    /// Open SFTP over the active SSH transport.
    func connect(using sshService: SSHNetworkService) async throws {
        #if os(macOS)
            if let openSSHSFTPClient, openSSHSFTPClient.isActive {
                if entries.isEmpty {
                    try await listDirectory()
                }
                return
            }
        #endif
        if let sftpClient, sftpClient.isActive {
            if entries.isEmpty {
                try await listDirectory()
            }
            return
        }
        sftpClient = nil
        #if os(macOS)
            openSSHSFTPClient = nil
        #endif

        Log.sftp.info("Opening SFTP session...")
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        #if os(macOS)
            if let client = try await sshService.openOpenSSHSFTPClient() {
                do {
                    let path = try await client.realPath()
                    openSSHSFTPClient = client
                    currentPath = path
                    Log.sftp.info("OpenSSH SFTP connected, initial path: \(self.currentPath)")
                    try await listDirectory()
                    return
                } catch {
                    client.close()
                    openSSHSFTPClient = nil
                    throw error
                }
            }
        #endif

        let client = try await sshService.openSFTPClient()
        do {
            let path = try await client.getRealPath(atPath: ".")
            sftpClient = client
            currentPath = path
            Log.sftp.info("SFTP connected, initial path: \(self.currentPath)")
            try await listDirectory()
        } catch {
            try? await client.close()
            sftpClient = nil
            throw error
        }
    }

    /// VNext — connect via unified SSHSession (single-connection multiplex, T5)
    func connect(using session: any SSHSession) async throws {
        if let vnextChannel {
            if entries.isEmpty { try await listDirectory() }
            return
        }
        vnextChannel = nil
        Log.sftp.info("Opening SFTP via VNext session...")
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let channel = try await session.openSFTP()
        let path = try await channel.realPath()
        vnextChannel = channel
        currentPath = path
        Log.sftp.info("VNext SFTP connected, initial path: \(self.currentPath)")
        try await listDirectory()
    }

    /// List files in the current directory.
    func listDirectory(_ path: String? = nil, showLoading: Bool = true) async throws {
        if let channel = vnextChannel {
            if showLoading { self.isLoading = true }
            self.errorMessage = nil
            defer { if showLoading { self.isLoading = false } }
            let targetPath = path ?? self.currentPath
            let requestID = self.beginListRequest()
            var result = try await channel.listDirectory(at: targetPath)
            guard requestID == self.listRequestSequence else { return }
            let sorted = await Task.detached(priority: .userInitiated) {
                result.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }.value
            guard requestID == self.listRequestSequence else { return }
            entries = sorted
            currentPath = targetPath
            return
        }
        #if os(macOS)
            if let sftp = openSSHSFTPClient {
                if showLoading {
                    self.isLoading = true
                }
                self.errorMessage = nil
                defer {
                    if showLoading {
                        self.isLoading = false
                    }
                }

                let targetPath = path ?? self.currentPath
                let requestID = self.beginListRequest()
                var result = try await sftp.listDirectory(at: targetPath)
                guard requestID == self.listRequestSequence else { return }
                let sorted = await Task.detached(priority: .userInitiated) {
                    result.sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }.value
                guard requestID == self.listRequestSequence else { return }
                entries = sorted
                currentPath = targetPath
                return
            }
        #endif

        guard let sftp = sftpClient else {
            Log.sftp.error("listDirectory failed: not connected")
            throw SFTPServiceError.notConnected
        }
        if showLoading {
            self.isLoading = true
        }
        self.errorMessage = nil
        defer {
            if showLoading {
                self.isLoading = false
            }
        }

        let targetPath = path ?? self.currentPath
        let requestID = beginListRequest()
        let names = try await sftp.listDirectory(atPath: targetPath)
        guard requestID == listRequestSequence else { return }

        var result: [SFTPFileEntry] = []
        for name in names {
            for component in name.components {
                // Skip . and ..
                if component.filename == "." || component.filename == ".." { continue }

                let isDir = component.longname.hasPrefix("d")
                let fullPath = pathJoin(targetPath, component.filename)

                result.append(SFTPFileEntry(
                    id: fullPath,
                    name: component.filename,
                    path: fullPath,
                    isDirectory: isDir,
                    size: component.attributes.size ?? 0,
                    permissions: component.attributes.permissions ?? 0,
                    modifiedAt: component.attributes.accessModificationTime?.modificationTime,
                    longname: component.longname
                ))
            }
        }

        // Sort off MainActor for large directories (10k entries)
        let sorted = await Task.detached(priority: .userInitiated) {
            result.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
        guard requestID == listRequestSequence else { return }

        entries = sorted
        currentPath = targetPath
    }

    /// Navigate to parent directory.
    func goUp() async throws {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        try await listDirectory(parent.isEmpty ? "/" : parent)
    }

    /// Navigate into a directory.
    func enterDirectory(_ entry: SFTPFileEntry) async throws {
        guard entry.isDirectory else { return }
        try await listDirectory(entry.path)
    }

    /// Create a new directory.
    func createDirectory(name: String) async throws {
        if let channel = vnextChannel {
            let newPath = pathJoin(currentPath, name)
            try await channel.createDirectory(at: newPath)
            try await listDirectory()
            return
        }
        #if os(macOS)
            if let sftp = openSSHSFTPClient {
                let newPath = pathJoin(currentPath, name)
                try await sftp.createDirectory(at: newPath)
                try await listDirectory()
                return
            }
        #endif

        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }
        let newPath = pathJoin(currentPath, name)
        try await sftp.createDirectory(atPath: newPath)
        try await listDirectory()
    }

    /// Delete a file or directory.
    func delete(_ entry: SFTPFileEntry) async throws {
        if let channel = vnextChannel {
            try await channel.remove(at: entry.path, isDirectory: entry.isDirectory)
            try await listDirectory()
            return
        }
        #if os(macOS)
            if let sftp = openSSHSFTPClient {
                try await sftp.remove(at: entry.path, isDirectory: entry.isDirectory)
                try await listDirectory()
                return
            }
        #endif

        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }
        if entry.isDirectory {
            try await sftp.rmdir(at: entry.path)
        } else {
            try await sftp.remove(at: entry.path)
        }
        try await listDirectory()
    }

    /// Download a file to local disk.
    func download(_ entry: SFTPFileEntry, to localURL: URL) async throws {
        if let channel = vnextChannel {
            guard !entry.isDirectory else { return }
            let transferID = UUID()
            transfers.append(SFTPTransfer(id: transferID, filename: entry.name, totalBytes: entry.size, transferredBytes: 0, isComplete: false, error: nil))
            do {
                try await channel.download(entry.path, to: localURL, operationID: transferID, onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        let clamped = min(max(progress, 0), 1)
                        if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                            self.transfers[idx].transferredBytes = UInt64(Double(entry.size) * clamped)
                        }
                    }
                })
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    transfers[idx].transferredBytes = entry.size
                    transfers[idx].isComplete = true
                }
                scheduleTransferRemoval(transferID, after: 3)
            } catch {
                markTransferError(transferID, error: error)
                scheduleTransferRemoval(transferID, after: 5)
                throw error
            }
            return
        }
        #if os(macOS)
            if let sftp = openSSHSFTPClient {
                guard !entry.isDirectory else { return }
                try await downloadWithOpenSSH(
                    sftp: sftp,
                    entry: entry,
                    localURL: localURL
                )
                return
            }
        #endif

        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }
        guard !entry.isDirectory else { return }

        let transferID = UUID()
        transfers.append(SFTPTransfer(
            id: transferID, filename: entry.name, totalBytes: entry.size,
            transferredBytes: 0, isComplete: false, error: nil
        ))

        do {
            try await sftp.withFile(filePath: entry.path, flags: .read) { file in
                try await self.downloadChunks(
                    file: file, entry: entry, localURL: localURL,
                    transferID: transferID
                )
            }
            self.markTransferComplete(transferID)
            self.scheduleTransferRemoval(transferID, after: 3)
        } catch {
            self.markTransferError(transferID, error: error)
            self.scheduleTransferRemoval(transferID, after: 5)
            throw error
        }
    }

    /// Download file chunks with progress updates.
    /// Reads are pipelined (multiple in flight) so throughput isn't limited to one
    /// round trip per chunk, then reassembled in order locally.
    /// P2: >500MB 自动分片并行（已知大小），否则单流 EOF 自适应。
    private func downloadChunks(
        file: SFTPFile, entry: SFTPFileEntry, localURL: URL,
        transferID: UUID
    ) async throws {
        // Sendable wrapper for the off-MainActor network reads below.
        let remoteFile = SendableSFTPFile(file)

        // P2 parallel download — 仅当大小已知且超过阈值
        if entry.size > 0, SFTPParallelStrategy.shouldUseParallel(totalBytes: entry.size) {
            Log.sftp.info("[P2] SFTPService downloadChunks parallel total=\(entry.size)")
            do {
                try await SFTPParallelTransferEngine.parallelDownload(
                    remoteFile: remoteFile,
                    localURL: localURL,
                    totalBytes: entry.size,
                    isCancelled: { [weak self] in
                        if Task.isCancelled { return true }
                        guard let self else { return false }
                        return await MainActor.run {
                            self.transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let clamped = min(max(progress, 0), 1)
                            if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                                self.transfers[idx].transferredBytes = UInt64(Double(entry.size) * clamped)
                            }
                        }
                    }
                )
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    transfers[idx].transferredBytes = entry.size
                }
                return
            } catch is CancellationError {
                throw SFTPServiceError.transferCancelled
            } catch let err as SFTPServiceError where err == .transferCancelled {
                throw err
            } catch {
                Log.sftp.warning("[P2] SFTPService parallelDownload failed, fallback: \(String(describing: error))")
                // 清理残留文件，准备单流重试
                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize)
        let pipelineDepth: Int = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: entry.size)
        var nextReadOffset: UInt64 = 0
        var nextWriteOffset: UInt64 = 0
        var pending: [UInt64: Data] = [:]
        var readDone = false
        var inFlight = 0
        var updateCounter = 0

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        // Don't rely on entry.size for loop control - it may be inaccurate
        // for some file types or SFTP servers. Read until EOF.
        try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
            while !readDone || inFlight > 0 {
                // Honor user cancellation (same pattern as writeChunks).
                let isCancelled = transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                if isCancelled { throw SFTPServiceError.transferCancelled }

                // Top up the read pipeline
                while !readDone && inFlight < pipelineDepth {
                    let readOffset = nextReadOffset
                    nextReadOffset += UInt64(chunkSize)
                    inFlight += 1
                    group.addTask {
                        // Network read runs off the MainActor (see SFTPTransferEngine).
                        try await SFTPTransferEngine.readChunk(
                            remoteFile, offset: readOffset, length: chunkSize
                        )
                    }
                }

                guard let (readOffset, data) = try await group.next() else { break }
                inFlight -= 1
                if data.isEmpty || data.count < chunkSize {
                    // SFTP servers return a short or empty read only at EOF.
                    readDone = true
                }
                if !data.isEmpty {
                    pending[readOffset] = data
                }

                // Write completed chunks back in order — off MainActor via detached
                while let bytes = pending.removeValue(forKey: nextWriteOffset) {
                    let bytesToWrite = bytes
                    try await Task.detached(priority: .userInitiated) {
                        try handle.write(contentsOf: bytesToWrite)
                    }.value
                    nextWriteOffset += UInt64(bytesToWrite.count)
                    updateCounter += 1
                    if updateCounter % 10 == 0 {
                        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                            transfers[idx].transferredBytes = nextWriteOffset
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        // Final progress update
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            transfers[idx].transferredBytes = nextWriteOffset
        }
    }

    /// Mark a transfer as complete.
    private func markTransferComplete(_ transferID: UUID) {
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            transfers[idx].isComplete = true
        }
    }

    /// Mark a transfer as failed.
    private func markTransferError(_ transferID: UUID, error: Error) {
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            transfers[idx].error = error.localizedDescription
        }
    }

    /// Schedule automatic removal of a transfer after a delay.
    private func scheduleTransferRemoval(_ transferID: UUID, after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.transfers.removeAll { $0.id == transferID }
        }
    }

    /// Cancel a specific transfer.
    func cancelTransfer(_ transferID: UUID) {
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            transfers[idx].isCancelled = true
        }
        #if os(macOS)
            openSSHSFTPClient?.cancel(operationID: transferID)
        #endif
    }

    /// Remove a specific transfer from the list.
    func removeTransfer(_ transferID: UUID) {
        transfers.removeAll { $0.id == transferID }
    }

    /// Upload a local file to the remote path. Returns an AsyncStream of progress (0.0 - 1.0).
    func upload(_ localURL: URL, to remotePath: String? = nil) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await performUpload(localURL, to: remotePath, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Internal upload implementation.
    private func performUpload(
        _ localURL: URL,
        to remotePath: String?,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        if let channel = vnextChannel {
            let targetPath = remotePath ?? pathJoin(currentPath, localURL.lastPathComponent)
            let filename = localURL.lastPathComponent
            let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
            let total = (attrs?[.size] as? UInt64) ?? 0
            let transferID = UUID()
            transfers.append(SFTPTransfer(id: transferID, filename: filename, totalBytes: total, transferredBytes: 0, isComplete: false, error: nil))
            do {
                try await channel.upload(localURL, to: targetPath, operationID: transferID, onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        let clamped = min(max(progress, 0), 1)
                        if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                            self.transfers[idx].transferredBytes = UInt64(Double(total) * clamped)
                        }
                        continuation.yield(clamped)
                    }
                })
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    transfers[idx].transferredBytes = total
                    transfers[idx].isComplete = true
                }
                continuation.yield(1.0)
                scheduleTransferRemoval(transferID, after: 3)
            } catch {
                markTransferError(transferID, error: error)
                scheduleTransferRemoval(transferID, after: 5)
                throw error
            }
            try? await listDirectory(showLoading: false)
            return
        }
        #if os(macOS)
            if let sftp = openSSHSFTPClient {
                try await performOpenSSHUpload(
                    localURL,
                    to: remotePath,
                    sftp: sftp,
                    continuation: continuation
                )
                return
            }
        #endif

        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }

        let filename = localURL.lastPathComponent
        let remote = remotePath ?? pathJoin(currentPath, filename)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalBytes = (fileAttributes[.size] as? UInt64) ?? 0

        let transferID = UUID()
        transfers.append(SFTPTransfer(
            id: transferID, filename: filename, totalBytes: totalBytes,
            transferredBytes: 0, isComplete: false, error: nil
        ))

        do {
            try await sftp.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
                try await self.writeChunks(
                    localURL: localURL, file: file, totalBytes: totalBytes,
                    transferID: transferID, continuation: continuation
                )

                await MainActor.run { [self] in
                    if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                        transfers[idx].isComplete = true
                    }
                }
                continuation.yield(1.0)
            }
        } catch {
            if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                if let sftpError = error as? SFTPServiceError, sftpError == .transferCancelled {
                    transfers[idx].isCancelled = true
                } else {
                    transfers[idx].error = error.localizedDescription
                }
            }
            throw error
        }

        // Refresh the listing, but don't turn a successful upload into a failure
        // just because the directory refresh errored.
        try? await listDirectory(showLoading: false)
    }

    #if os(macOS)
        private func performOpenSSHUpload(
            _ localURL: URL,
            to remotePath: String?,
            sftp: OpenSSHSFTPClient,
            continuation: AsyncThrowingStream<Double, Error>.Continuation
        ) async throws {
            let filename = localURL.lastPathComponent
            let remote = remotePath ?? pathJoin(currentPath, filename)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let totalBytes = (fileAttributes[.size] as? UInt64) ?? 0
            let transferID = UUID()

            transfers.append(SFTPTransfer(
                id: transferID,
                filename: filename,
                totalBytes: totalBytes,
                transferredBytes: 0,
                isComplete: false,
                error: nil
            ))
            continuation.yield(0)

            do {
                try await sftp.upload(
                    localURL,
                    to: remote,
                    operationID: transferID,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let clamped = min(max(progress, 0), 1)
                            if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                                self.transfers[idx].transferredBytes = UInt64(
                                    Double(totalBytes) * clamped
                                )
                            }
                            continuation.yield(clamped)
                        }
                    }
                )
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    transfers[idx].transferredBytes = totalBytes
                    transfers[idx].isComplete = true
                }
                continuation.yield(1.0)
            } catch {
                if let sftpError = error as? SFTPServiceError, sftpError == .transferCancelled {
                    if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                        transfers[idx].isCancelled = true
                    }
                } else {
                    markTransferError(transferID, error: error)
                }
                scheduleTransferRemoval(transferID, after: 5)
                throw error
            }

            // Refresh listing, but don't turn a successful upload into a failure
            // just because the directory refresh errored.
            try? await listDirectory(showLoading: false)
        }

        private func downloadWithOpenSSH(
            sftp: OpenSSHSFTPClient,
            entry: SFTPFileEntry,
            localURL: URL
        ) async throws {
            let transferID = UUID()
            transfers.append(SFTPTransfer(
                id: transferID,
                filename: entry.name,
                totalBytes: entry.size,
                transferredBytes: 0,
                isComplete: false,
                error: nil
            ))

            do {
                try await sftp.download(
                    entry.path,
                    to: localURL,
                    operationID: transferID,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let clamped = min(max(progress, 0), 1)
                            if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                                self.transfers[idx].transferredBytes = UInt64(
                                    Double(entry.size) * clamped
                                )
                            }
                        }
                    }
                )
                let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
                let transferredBytes = (attributes?[.size] as? UInt64) ?? entry.size
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    transfers[idx].transferredBytes = transferredBytes
                    transfers[idx].isComplete = true
                }
                scheduleTransferRemoval(transferID, after: 3)
            } catch {
                if let sftpError = error as? SFTPServiceError, sftpError == .transferCancelled {
                    if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                        transfers[idx].isCancelled = true
                    }
                } else {
                    markTransferError(transferID, error: error)
                }
                scheduleTransferRemoval(transferID, after: 5)
                throw error
            }
        }
    #endif

    /// Write file chunks with pipelined concurrent writes.
    /// File IO is off MainActor via SFTPTransferActor (DispatchIO), pipeline 1024×32KB=32MB.
    /// P2: >500MB 自动切分片并行（4/8 shards），否则保持原自适应单流。
    private func writeChunks(
        localURL: URL,
        file: SFTPFile,
        totalBytes: UInt64,
        transferID: UUID,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        let remoteFile = SendableSFTPFile(file)

        // P2 parallel path — 仅 Citadel Native 路径，OpenSSH 路径已在 performUpload 分流
        if SFTPParallelStrategy.shouldUseParallel(totalBytes: totalBytes) {
            Log.sftp.info("[P2] SFTPService writeChunks parallel total=\(totalBytes)")
            do {
                try await SFTPParallelTransferEngine.parallelUpload(
                    localURL: localURL,
                    remoteFile: remoteFile,
                    totalBytes: totalBytes,
                    isCancelled: { [weak self] in
                        if Task.isCancelled { return true }
                        guard let self else { return false }
                        // Hop 到 MainActor 读取取消标记
                        return await MainActor.run {
                            self.transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let clamped = min(max(progress, 0), 1)
                            if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                                self.transfers[idx].transferredBytes = UInt64(Double(totalBytes) * clamped)
                            }
                            continuation.yield(clamped)
                        }
                    }
                )
                // 额外 MainActor 取消检查（用户点取消按钮）
                if transfers.first(where: { $0.id == transferID })?.isCancelled == true {
                    throw SFTPServiceError.transferCancelled
                }
                return
            } catch is CancellationError {
                throw SFTPServiceError.transferCancelled
            } catch let err as SFTPServiceError where err == .transferCancelled {
                throw err
            } catch {
                Log.sftp.warning("[P2] SFTPService parallelUpload failed, fallback to single stream: \(String(describing: error))")
                // fallthrough to single stream
            }
        }

        let chunkSize = SFTPParallelStrategy.chunkSize
        let pipelineDepth: Int = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: totalBytes)
        let reader = try SFTPTransferActor(url: localURL)
        defer { Task { await reader.close() } }
        var offset: UInt64 = 0
        var completedBytes: UInt64 = 0
        var pending = 0
        var updateCounter = 0
        var lastReportedProgress: Double = -1

        try await withThrowingTaskGroup(of: Int.self) { group in
            while true {
                let isCancelled = transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                if isCancelled { throw SFTPServiceError.transferCancelled }

                // Top up the write pipeline — file read off MainActor via actor
                while pending < pipelineDepth {
                    let chunkData = try await reader.readChunk(offset: offset, length: chunkSize)
                    guard !chunkData.isEmpty else { break }
                    let chunkOffset = offset
                    offset += UInt64(chunkData.count)
                    pending += 1
                    group.addTask {
                        try await SFTPTransferEngine.writeChunk(
                            remoteFile, data: chunkData, at: chunkOffset
                        )
                    }
                }

                if pending == 0 { break }
                // Wait for the oldest write to complete
                guard let written = try await group.next() else { break }
                pending -= 1
                completedBytes += UInt64(written)
                updateCounter += 1

                if updateCounter % 10 == 0 || completedBytes == totalBytes {
                    if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                        transfers[idx].transferredBytes = completedBytes
                    }
                    let progress = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1.0
                    if progress - lastReportedProgress >= 0.01 || completedBytes == totalBytes {
                        lastReportedProgress = progress
                        continuation.yield(progress)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Check if a file exists at the given absolute path.
    /// Returns nil when the check itself fails (e.g. network error).
    func fileExists(at path: String) async -> Bool? {
        #if os(macOS)
            if let sftp = openSSHSFTPClient {
                return await sftp.fileExists(at: path)
            }
        #endif

        guard let sftp = sftpClient else { return nil }
        do {
            // Try to open the file for reading - this is the most reliable way
            // because it doesn't rely on cached directory listings
            let file = try await sftp.openFile(filePath: path, flags: [.read])
            try await file.close()
            Log.sftp.debug("fileExists check: \(path) -> true (openFile succeeded)")
            return true
        } catch {
            // File doesn't exist or can't be opened
            Log.sftp.debug("fileExists check: \(path) -> false (openFile failed: \(error.localizedDescription))")
            return false
        }
    }

    /// Refresh the current path from the remote server.
    func refreshCurrentPath() async {
        #if os(macOS)
            if let sftp = openSSHSFTPClient {
                do {
                    currentPath = try await sftp.realPath()
                } catch {
                    Log.sftp.warning("Failed to refresh current path: \(error.localizedDescription)")
                }
                return
            }
        #endif

        guard let sftp = sftpClient else { return }
        do {
            currentPath = try await sftp.getRealPath(atPath: ".")
        } catch {
            Log.sftp.warning("Failed to refresh current path: \(error.localizedDescription)")
        }
    }

    /// Close the SFTP session.
    func disconnect() async {
        if let channel = vnextChannel { await channel.close() }
        vnextChannel = nil
        #if os(macOS)
            openSSHSFTPClient?.close()
            openSSHSFTPClient = nil
        #endif
        try? await sftpClient?.close()
        sftpClient = nil
        entries = []
        // Cancel any in-flight transfers
        for transfer in transfers where !transfer.isComplete {
            if let idx = transfers.firstIndex(where: { $0.id == transfer.id }) { transfers[idx].isCancelled = true }
        }
    }

    private func pathJoin(_ base: String, _ component: String) -> String {
        URL(fileURLWithPath: base).appendingPathComponent(component).path
    }
}

enum SFTPServiceError: LocalizedError, Equatable {
    case notConnected
    case transferCancelled
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "SFTP session not connected."
        case .transferCancelled: "Transfer cancelled."
        case let .operationFailed(message): message
        }
    }
}

// MARK: - Transfer Engine (off MainActor)

/// Wraps Citadel's SFTPFile so chunk I/O can run outside the MainActor.
/// SFTPFile serializes requests internally via channel request IDs, so
/// concurrent reads/writes are safe; the wrapper only satisfies Swift 6
/// Sendable checks.
final class SendableSFTPFile: @unchecked Sendable {
    let file: SFTPFile
    init(_ file: SFTPFile) { self.file = file }
}

/// SFTP chunk I/O executed OUTSIDE the MainActor. Network round trips are
/// the transfer bottleneck; running 16 in-flight requests on the main thread
/// froze the UI during large transfers. Local disk I/O stays on the main
/// thread — sequential 32KB writes are orders of magnitude faster than the
/// network and never become the bottleneck.
enum SFTPTransferEngine {
    nonisolated static func readChunk(
        _ file: SendableSFTPFile,
        offset: UInt64,
        length: UInt32
    ) async throws -> (UInt64, Data) {
        let data = try await file.file.read(from: offset, length: length)
        return (offset, Data(buffer: data))
    }

    nonisolated static func writeChunk(
        _ file: SendableSFTPFile,
        data: Data,
        at offset: UInt64
    ) async throws -> Int {
        // Zero-copy: avoid Data→Array→ByteBuffer double copy via direct ByteBufferAllocator
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        data.withUnsafeBytes { ptr in
            buffer.writeBytes(ptr)
        }
        try await file.file.write(buffer, at: offset)
        return data.count
    }

    nonisolated static func writeBuffer(
        _ file: SendableSFTPFile,
        buffer: ByteBuffer,
        at offset: UInt64
    ) async throws -> Int {
        // True zero-copy: buffer already from pread, no Data intermediate
        var buf = buffer
        let count = buf.readableBytes
        try await file.file.write(buf, at: offset)
        return count
    }
}
