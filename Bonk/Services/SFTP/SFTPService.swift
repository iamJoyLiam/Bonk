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

    /// List files in the current directory.
    func listDirectory(_ path: String? = nil, showLoading: Bool = true) async throws {
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
                var result = try await sftp.listDirectory(at: targetPath)
                result.sort {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                entries = result
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
        let names = try await sftp.listDirectory(atPath: targetPath)

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

        // Sort: directories first, then by name
        result.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        entries = result
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
    private func downloadChunks(
        file: SFTPFile, entry: SFTPFileEntry, localURL: URL,
        transferID: UUID
    ) async throws {
        // 32_000 fits within the SSH channel's max packet size (Citadel uses the
        // same limit internally for writes).
        let chunkSize: UInt32 = 32_000
        // In-flight read window: 16 × 32KB = 512KB, enough to keep a high-latency
        // link saturated without buffering the whole file in memory.
        let pipelineDepth = 16
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
                // Top up the read pipeline
                while !readDone && inFlight < pipelineDepth {
                    let readOffset = nextReadOffset
                    nextReadOffset += UInt64(chunkSize)
                    inFlight += 1
                    group.addTask {
                        let data = try await file.read(from: readOffset, length: chunkSize)
                        return (readOffset, Data(buffer: data))
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

                // Write completed chunks back in order
                while let bytes = pending.removeValue(forKey: nextWriteOffset) {
                    try handle.write(contentsOf: bytes)
                    nextWriteOffset += UInt64(bytes.count)
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

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        do {
            try await sftp.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
                try await self.writeChunks(
                    handle: handle, file: file, totalBytes: totalBytes,
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
    /// SFTP is request/response: a write waits for the server's status reply, so
    /// sequential writes cost one round trip per 32KB chunk. Keeping multiple
    /// writes in flight raises throughput to window/RTT instead of 32KB/RTT.
    private func writeChunks(
        handle: FileHandle,
        file: SFTPFile,
        totalBytes: UInt64,
        transferID: UUID,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        // 32_000 matches Citadel's internal SFTP write slice (SFTPFile.write).
        // Larger buffers are split into sequential 32KB requests anyway.
        let chunkSize = 32_000
        // In-flight write window: 16 × 32KB = 512KB.
        let pipelineDepth = 16
        var offset: UInt64 = 0
        var completedBytes: UInt64 = 0
        var pending = 0
        var updateCounter = 0
        var lastReportedProgress: Double = -1

        try await withThrowingTaskGroup(of: Int.self) { group in
            while true {
                let isCancelled = transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                if isCancelled { throw SFTPServiceError.transferCancelled }

                // Top up the write pipeline
                while pending < pipelineDepth {
                    guard let chunkData = try handle.read(upToCount: chunkSize), !chunkData.isEmpty else { break }
                    let chunkOffset = offset
                    offset += UInt64(chunkData.count)
                    pending += 1
                    var buffer = ByteBuffer(data: chunkData)
                    group.addTask {
                        try await file.write(buffer, at: chunkOffset)
                        return chunkData.count
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
        #if os(macOS)
            openSSHSFTPClient?.close()
            openSSHSFTPClient = nil
        #endif
        try? await sftpClient?.close()
        sftpClient = nil
        entries = []
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
