//
//  SFTPModels.swift
//  Bonk
//

import Foundation

/// Represents a remote file or directory from SFTP listing.
public struct SFTPFileEntry: Identifiable, Sendable, Equatable {
    public let id: String // path-based identity for stable SwiftUI diffing
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64
    public let permissions: UInt32
    public let modifiedAt: Date?
    public let longname: String

    public init(id: String, name: String, path: String, isDirectory: Bool, size: UInt64, permissions: UInt32, modifiedAt: Date?, longname: String) {
        self.id = id; self.name = name; self.path = path; self.isDirectory = isDirectory
        self.size = size; self.permissions = permissions; self.modifiedAt = modifiedAt; self.longname = longname
    }

    var permissionsString: String {
        let perms = permissions
        var permString = isDirectory ? "d" : "-"
        permString += (perms & 0o400) != 0 ? "r" : "-"
        permString += (perms & 0o200) != 0 ? "w" : "-"
        permString += (perms & 0o100) != 0 ? "x" : "-"
        permString += (perms & 0o040) != 0 ? "r" : "-"
        permString += (perms & 0o020) != 0 ? "w" : "-"
        permString += (perms & 0o010) != 0 ? "x" : "-"
        permString += (perms & 0o004) != 0 ? "r" : "-"
        permString += (perms & 0o002) != 0 ? "w" : "-"
        permString += (perms & 0o001) != 0 ? "x" : "-"
        return permString
    }

    var sizeFormatted: String {
        if isDirectory { return "--" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        if size < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(size) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(size) / (1024 * 1024 * 1024))
    }
}

/// Coalesces I/O → MainActor hops: 50ms (≈20 FPS), never drops 1.0
final class SFTPProgressThrottler: @unchecked Sendable {
    static let shared = SFTPProgressThrottler()
    private let lock = NSLock()
    private var last: [UUID: Date] = [:]
    private let interval: TimeInterval = 0.05 // 20 FPS, as spec: 50~100ms
    func shouldEmit(id: UUID, progress: Double) -> Bool {
        if progress >= 1.0 { // always pass completion
            lock.lock(); last[id] = Date(); lock.unlock(); return true
        }
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        if let prev = last[id], now.timeIntervalSince(prev) < interval { return false }
        last[id] = now; return true
    }
    func remove(id: UUID) { lock.lock(); last.removeValue(forKey: id); lock.unlock() }
}

/// Transfer progress for file upload/download.
/// Known size: fraction = transferred/total, determinate ProgressView.
/// Unknown size: totalBytes == nil, progress == nil -> indeterminate ProgressView + MB only.
@Observable
final class SFTPTransfer: Identifiable {
    let id: UUID
    let filename: String
    var totalBytes: UInt64? // nil = unknown (e.g. SFTP attrs.size == 0)
    var transferredBytes: UInt64
    var isComplete: Bool
    var isCancelled: Bool = false
    var error: String?
    /// Internal smooth fraction for known-size determinate UI (throttled 50~100ms, not per-byte)
    var fraction: Double = 0
    @ObservationIgnored var lastUIUpdate = Date.distantPast

    init(id: UUID, filename: String, totalBytes: UInt64?, transferredBytes: UInt64, isComplete: Bool, isCancelled: Bool = false, error: String? = nil) {
        self.id = id; self.filename = filename; self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes; self.isComplete = isComplete
        self.isCancelled = isCancelled; self.error = error
    }
    // Convenience for known size (UInt64)
    convenience init(id: UUID, filename: String, totalBytes: UInt64, transferredBytes: UInt64, isComplete: Bool, isCancelled: Bool = false, error: String? = nil) {
        self.init(id: id, filename: filename, totalBytes: totalBytes == 0 ? nil : totalBytes, transferredBytes: transferredBytes, isComplete: isComplete, isCancelled: isCancelled, error: error)
    }

    /// Nil when unknown size -> UI shows indeterminate ProgressView()
    var progress: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(Double(transferredBytes) / Double(total), 1.0)
    }

    var isActive: Bool { !isComplete && !isCancelled }
}
