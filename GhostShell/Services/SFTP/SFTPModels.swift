//
//  SFTPModels.swift
//  GhostShell
//

import Foundation

/// Represents a remote file or directory from SFTP listing.
struct SFTPFileEntry: Identifiable, Sendable {
    let id: String  // path-based identity for stable SwiftUI diffing
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: UInt32
    let modifiedAt: Date?
    let longname: String

    var permissionsString: String {
        let perms = permissions
        var s = isDirectory ? "d" : "-"
        s += (perms & 0o400) != 0 ? "r" : "-"
        s += (perms & 0o200) != 0 ? "w" : "-"
        s += (perms & 0o100) != 0 ? "x" : "-"
        s += (perms & 0o040) != 0 ? "r" : "-"
        s += (perms & 0o020) != 0 ? "w" : "-"
        s += (perms & 0o010) != 0 ? "x" : "-"
        s += (perms & 0o004) != 0 ? "r" : "-"
        s += (perms & 0o002) != 0 ? "w" : "-"
        s += (perms & 0o001) != 0 ? "x" : "-"
        return s
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
struct SFTPTransfer: Identifiable, Sendable {
    let id: UUID
    let filename: String
    let totalBytes: UInt64
    var transferredBytes: UInt64
    var isComplete: Bool
    var error: String?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }
}
