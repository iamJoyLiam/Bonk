//
//  SFTPService.swift
//  Bonk
//

@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import os.log

/// High-level SFTP operations wrapping Citadel's SFTPClient.
@Observable
@MainActor
final class SFTPService {
    var currentPath: String = "/"
    var entries: [SFTPFileEntry] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var transfers: [SFTPTransfer] = []

    private var sftpClient: SFTPClient?

    init() {}

    /// Open SFTP subsystem over the existing SSH connection.
    func connect(using sshService: SSHNetworkService) async throws {
        Log.sftp.info("Opening SFTP session...")
        let client = try await sshService.openSFTPClient()
        sftpClient = client
        currentPath = try await client.getRealPath(atPath: ".")
        Log.sftp.info("SFTP connected, initial path: \(self.currentPath)")
        // Brief delay to ensure SFTP session is fully initialized
        try? await Task.sleep(for: .milliseconds(200))
        try await listDirectory()
    }

    /// List files in the current directory.
    func listDirectory(_ path: String? = nil) async throws {
        guard let sftp = sftpClient else {
            Log.sftp.error("listDirectory failed: not connected")
            throw SFTPServiceError.notConnected
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let targetPath = path ?? currentPath
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
        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }
        let newPath = pathJoin(currentPath, name)
        try await sftp.createDirectory(atPath: newPath)
        try await listDirectory()
    }

    /// Delete a file or directory.
    func delete(_ entry: SFTPFileEntry) async throws {
        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }
        if entry.isDirectory {
            try await sftp.rmdir(at: entry.path)
        } else {
            try await sftp.remove(at: entry.path)
        }
        try await listDirectory()
    }

    /// Rename/move a file or directory.
    func rename(_ entry: SFTPFileEntry, to newName: String) async throws {
        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }
        let newPath = (entry.path as NSString).deletingLastPathComponent + "/" + newName
        try await sftp.rename(at: entry.path, to: newPath)
        try await listDirectory()
    }

    /// Download a file to local disk.
    func download(_ entry: SFTPFileEntry, to localURL: URL) async throws {
        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }
        guard !entry.isDirectory else { return }

        let transferID = UUID()
        await MainActor.run {
            transfers.append(SFTPTransfer(
                id: transferID, filename: entry.name, totalBytes: entry.size,
                transferredBytes: 0, isComplete: false, error: nil
            ))
        }

        do {
            try await sftp.withFile(filePath: entry.path, flags: .read) { file in
                let chunkSize: UInt32 = 32768
                var offset: UInt64 = 0
                FileManager.default.createFile(atPath: localURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: localURL)
                defer { try? handle.close() }

                var updateCounter = 0
                while offset < entry.size {
                    let toRead = min(UInt64(chunkSize), entry.size - offset)
                    let data = try await file.read(from: offset, length: UInt32(toRead))
                    guard data.readableBytes > 0 else { break }
                    let bytes = Data(buffer: data)
                    try handle.write(contentsOf: bytes)
                    offset += UInt64(bytes.count)
                    updateCounter += 1
                    if updateCounter % 10 == 0 || offset >= entry.size {
                        let off = offset
                        await MainActor.run { [self] in
                            if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                                transfers[idx].transferredBytes = off
                            }
                        }
                    }
                }
                await MainActor.run { [self] in
                    if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                        transfers[idx].isComplete = true
                    }
                }
            }
        } catch {
            if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                transfers[idx].error = error.localizedDescription
            }
            throw error
        }
    }

    /// Cancel a specific transfer.
    func cancelTransfer(_ transferID: UUID) {
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            transfers[idx].isCancelled = true
        }
    }

    /// Upload a local file to the remote path. Streams in chunks to avoid OOM.
    func upload(_ localURL: URL, to remotePath: String? = nil) async throws {
        guard let sftp = sftpClient else { throw SFTPServiceError.notConnected }

        let filename = localURL.lastPathComponent
        let remote = remotePath ?? pathJoin(currentPath, filename)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalBytes = (fileAttributes[.size] as? UInt64) ?? 0

        let transferID = UUID()
        await MainActor.run { [self] in
            transfers.append(SFTPTransfer(
                id: transferID, filename: filename, totalBytes: totalBytes,
                transferredBytes: 0, isComplete: false, error: nil
            ))
        }

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        do {
            try await sftp.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
                var offset: UInt64 = 0
                let chunkSize = 32768
                var updateCounter = 0

                while true {
                    // Check for cancellation
                    let isCancelled = await MainActor.run { [self] in
                        transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                    }
                    if isCancelled {
                        throw SFTPServiceError.transferCancelled
                    }

                    guard let chunkData = try handle.read(upToCount: chunkSize), !chunkData.isEmpty else { break }
                    var buffer = ByteBuffer(data: chunkData)
                    try await file.write(buffer, at: offset)
                    offset += UInt64(chunkData.count)
                    updateCounter += 1

                    // Update progress every 10 chunks to reduce MainActor hops
                    if updateCounter % 10 == 0 || offset == totalBytes {
                        let off = offset
                        await MainActor.run { [self] in
                            if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                                transfers[idx].transferredBytes = off
                            }
                        }
                    }
                }
                await MainActor.run { [self] in
                    if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                        transfers[idx].isComplete = true
                    }
                }
            }
        } catch {
            if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                if error is SFTPServiceError && (error as! SFTPServiceError) == .transferCancelled {
                    transfers[idx].isCancelled = true
                } else {
                    transfers[idx].error = error.localizedDescription
                }
            }
            throw error
        }

        try await listDirectory()
    }

    /// Check if a file exists at the given absolute path.
    /// Returns nil when the check itself fails (e.g. network error).
    func fileExists(at path: String) async -> Bool? {
        guard let sftp = sftpClient else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        guard !parent.isEmpty, !filename.isEmpty else { return nil }
        do {
            let names = try await sftp.listDirectory(atPath: parent.isEmpty ? "/" : parent)
            return names.contains { component in
                component.components.contains { $0.filename == filename }
            }
        } catch {
            Log.sftp.warning("fileExists check failed for \(path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Refresh the current path from the remote server.
    func refreshCurrentPath() async {
        guard let sftp = sftpClient else { return }
        do {
            currentPath = try await sftp.getRealPath(atPath: ".")
        } catch {
            Log.sftp.warning("Failed to refresh current path: \(error.localizedDescription)")
        }
    }

    /// Close the SFTP session.
    func disconnect() async {
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

    var errorDescription: String? {
        switch self {
        case .notConnected: "SFTP session not connected."
        case .transferCancelled: "Transfer cancelled."
        }
    }
}
