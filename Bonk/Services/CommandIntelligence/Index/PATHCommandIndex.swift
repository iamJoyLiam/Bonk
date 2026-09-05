//  PATHCommandIndex.swift
//  Bonk
//
//  Asynchronous system PATH executables index.
//

import Foundation
import os

/// Background-scanned index of executables present in system PATH directories.
final class PATHCommandIndex: CommandIndex, @unchecked Sendable {
    static let shared = PATHCommandIndex()

    private let pathExecutables = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private let scanStarted = OSAllocatedUnfairLock<Bool>(initialState: false)

    init() {
        startBackgroundScan()
    }

    func matches(prefix: String, limit: Int = 5) -> [InlineCandidate] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let builtin = BuiltinCommandIndex.shared.allNames
        let candidates: [String] = pathExecutables.withLock { all in
            all.filter { cmd in
                let lower = cmd.lowercased()
                return lower.hasPrefix(trimmed) && lower.count > trimmed.count && !builtin.contains(cmd)
            }
        }

        let sorted = candidates.sorted { a, b in
            if a.count != b.count { return a.count < b.count }
            return a < b
        }

        return sorted.prefix(limit).map { cmd in
            let suffix = String(cmd.dropFirst(trimmed.count))
            let sug = Suggestion(text: suffix, displayText: suffix, fullText: cmd)
            return InlineCandidate(
                source: .pathExecutable,
                authority: .deterministic,
                suggestion: sug,
                rawScore: 72.0,
                isExactPrefixMatch: false,
                summary: "Executable in PATH"
            )
        }
    }

    private func startBackgroundScan() {
        let shouldStart = scanStarted.withLock { started -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        Task.detached(priority: .utility) { [weak self] in
            let found = Self.scanDirectories()
            guard let self, !found.isEmpty else { return }
            self.pathExecutables.withLock { $0 = found }
        }
    }

    private static func scanDirectories() -> Set<String> {
        let searchPath = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        var collected = Set<String>()
        for directory in searchPath.split(separator: ":") {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: String(directory)) {
                for entry in entries where !entry.contains(".") {
                    collected.insert(entry)
                }
            }
        }
        return collected
    }
}
