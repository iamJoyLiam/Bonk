//
//  SessionImporter.swift
//  Bonk
//
//  Protocol for importing sessions from external SSH clients.
//

import Foundation

/// Unified importer for external SSH client sessions.
protocol SessionImporter: Sendable {
    var name: String { get }
    var fileExtensions: [String] { get }
    /// Whether this importer can handle the given file.
    func canImport(url: URL) -> Bool
    /// Parse file and return HostItems (not yet inserted into SwiftData).
    func importSessions(from url: URL) throws -> [HostItem]
    /// Default locations to discover (e.g. ~/.config/tabby/config.yaml).
    func discoverDefaultLocations() -> [URL]
}

extension SessionImporter {
    func canImport(url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Import Errors

enum SessionImportError: Error, LocalizedError {
    case unsupportedFormat
    case parseFailed(String)
    case noSessionsFound

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Unsupported file format"
        case .parseFailed(let msg): "Parse failed: \(msg)"
        case .noSessionsFound: "No SSH sessions found in file"
        }
    }
}
