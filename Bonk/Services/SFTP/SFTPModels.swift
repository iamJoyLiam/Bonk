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

/// Transfer progress for file upload/download.
@Observable
final class SFTPTransfer: Identifiable {
    let id: UUID
    let filename: String
    var totalBytes: UInt64
    var transferredBytes: UInt64
    var isComplete: Bool
    var isCancelled: Bool = false
    var error: String?
    @ObservationIgnored var lastUIUpdate = Date.distantPast

    init(id: UUID, filename: String, totalBytes: UInt64, transferredBytes: UInt64, isComplete: Bool, isCancelled: Bool = false, error: String? = nil) {
        self.id = id; self.filename = filename; self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes; self.isComplete = isComplete
        self.isCancelled = isCancelled; self.error = error
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(transferredBytes) / Double(totalBytes), 1.0)
    }

    var isActive: Bool { !isComplete && !isCancelled }
}
