//
//  PTYEchoTracker.swift
//  Bonk — PTY input/output correlation for command echo detection
//
//  Ultimate path: preciseEcho via PTY input tracking beats heuristic.
//  Heuristic (shellVerbs list) remains fallback only; never expand it.
//

import Foundation

final class PTYEchoTracker: @unchecked Sendable {
    static let shared = PTYEchoTracker()

    private let lock = NSLock()
    private var recent: [String] = [] // lowercased trimmed
    private let maxEntries = 64
    private let maxLen = 512

    /// Record user input (from PTYSession.sendInput / ShellIntegration OSC133 C)
    func record(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLen, text.count >= 2 else { return }
        let lower = text.lowercased()
        // Filter control noise
        if lower == "\r" || lower == "\n" { return }
        lock.lock()
        // Deduplicate consecutive identical
        if recent.last != lower {
            recent.append(lower)
            if recent.count > maxEntries { recent.removeFirst(recent.count - maxEntries) }
        }
        lock.unlock()
    }

    /// True if line is (or contains) a recent user input echo.
    /// Precision > recall: require strong match, not substring of short token.
    func isEcho(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return false }
        let lower = trimmed.lowercased()
        // Exact match
        lock.lock()
        let snapshot = recent
        lock.unlock()
        for input in snapshot {
            if input.count < 3 { continue }
            if lower == input { return true }
            // Prompt + command: "root@host:~# docker ps" contains "docker ps"
            // Also " $ docker ps " with spaces
            if lower.contains(input), input.count >= 4 {
                // Guard: input is at least a verb + arg, avoid single word false positive like "ps"
                // Require input contains space or is long verb
                if input.contains(" ") || input.count >= 6 {
                    // Check input appears as token suffix (after prompt char)
                    // Simple: if line has prompt chars then input is suffix/prefix
                    if lower.hasSuffix(input) || lower.contains(" " + input) || lower.contains("# " + input) || lower.contains("$ " + input) {
                        return true
                    }
                }
            }
        }
        return false
    }

    func reset() {
        lock.lock()
        recent.removeAll()
        lock.unlock()
    }
}
