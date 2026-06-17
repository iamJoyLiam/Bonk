//
//  SessionBufferCache.swift
//  Bonk
//
//  Manages terminal output persistence for session restore.
//  Saves terminal output to local files for replay on app restart.
//

import Foundation
import os.log

/// Manages terminal output caching for session restoration.
/// Stores raw terminal bytes (including ANSI codes) to disk for replay.
final class SessionBufferCache: @unchecked Sendable {
    static let shared = SessionBufferCache()

    private let logger = Logger(subsystem: "com.bonk", category: "SessionBufferCache")
    private let cacheDirectory: URL
    private let maxLinesPerSession = 10_000
    private let maxFileSize = 5 * 1024 * 1024 // 5 MB per session

    private init() {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesPath.appendingPathComponent("Bonk/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Append terminal output bytes to the session cache file.
    func appendOutput(_ bytes: [UInt8], for sessionID: String) {
        let fileURL = cacheFile(for: sessionID)
        let data = Data(bytes)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Append to existing file
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()

                // Truncate if too large
                truncateIfNeeded(fileURL: fileURL)
            }
        } else {
            // Create new file
            try? data.write(to: fileURL)
        }
    }

    /// Read cached terminal output for a session.
    /// Returns the raw bytes that can be fed to SwiftTerm.
    func readOutput(for sessionID: String, maxBytes: Int? = nil) -> [UInt8]? {
        let fileURL = cacheFile(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let limit = maxBytes ?? maxFileSize
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }

        // Read from the end if file is larger than limit
        if data.count > limit {
            let startIndex = data.count - limit
            return Array(data[startIndex...])
        }
        return Array(data)
    }

    /// Delete cached output for a session.
    func clearOutput(for sessionID: String) {
        let fileURL = cacheFile(for: sessionID)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Clear all cached sessions.
    func clearAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Get the cache file size for a session.
    func cacheSize(for sessionID: String) -> Int {
        let fileURL = cacheFile(for: sessionID)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    // MARK: - Private

    private func cacheFile(for sessionID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(sessionID).term")
    }

    private func truncateIfNeeded(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return }
        if data.count > maxFileSize {
            // Keep the last 80% of max size
            let keepSize = Int(Double(maxFileSize) * 0.8)
            let startIndex = data.count - keepSize
            let truncated = Data(data[startIndex...])
            try? truncated.write(to: fileURL)
            logger.info("Truncated session cache to \(truncated.count) bytes")
        }
    }
}
