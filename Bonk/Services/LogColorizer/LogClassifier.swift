//
//  LogClassifier.swift
//  Bonk
//
//  Two-stage pipeline: LogClassifier (is this line a log?) -> LogTokenizer (highlight spans)
//  Precision > Recall, shell prompt priority, byte-scanner hot path, multiline state.
//

import Foundation

enum LogClassification {
    case log
    case notLog
    case continuation // multiline stack trace / indented continuation
}

final class LogClassifier: @unchecked Sendable {
    // MARK: - State for multiline (protected by lock for background worker)
    private let stateLock = NSLock()
    private var _previousWasLog = false
    private var previousWasLog: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _previousWasLog }
        set { stateLock.lock(); _previousWasLog = newValue; stateLock.unlock() }
    }
    private var previousIndent: Int = 0

    // Byte-scanner hot path: check prefix bytes before regex
    // Strong signatures: timestamp+level, ISO8601, syslog PRI, nginx, Java
    func classify(_ line: String) -> LogClassification {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .notLog }

        // 0. Shell prompt / command echo — highest priority (precision)
        if isShellPrompt(line) { 
            previousWasLog = false
            return .notLog 
        }
        // Ultimate: PTY input correlation beats heuristic
        if PTYEchoTracker.shared.isEcho(line) {
            previousWasLog = false
            return .notLog
        }
        if isCommandEcho(line) {
            previousWasLog = false
            return .notLog
        }

        // 0.5. Multiline continuation: indented stack trace after a log
        if previousWasLog, isContinuation(line) {
            return .continuation
        }

        // 1. Byte scanner fast path — check prefix bytes without regex
        // This is the hot path for 5000+ lines/sec, avoids NSRegularExpression for non-logs
        // Zero-copy: no Array allocation, operates on String.utf8 view directly
        if let strong = byteScannerStrongMatch(line) {
            previousWasLog = true
            return strong ? .log : .notLog
        }

        // 2. Strong signature via cached regex (fallback, still precise)
        if hasStrongSignature(line) {
            previousWasLog = true
            return .log
        }

        // 3. Not a log — even if it contains isolated level keywords like "alert"
        previousWasLog = false
        return .notLog
    }

    func reset() {
        previousWasLog = false
        previousIndent = 0
    }

    // MARK: - Shell prompt / echo

    private func isShellPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // Matches: [root@server ~]# , root@server:~$ , ubuntu@server:~$ , $ , % , ❯
        // Also matches the prompt + command: "[root@server ~]# echo ERROR"
        if t.hasPrefix("[") && t.contains("]#") { return true }
        if t.contains("@") && (t.contains(":$") || t.contains("~$") || t.contains("]#") || t.contains("~#")) { return true }
        if t == "$" || t == "%" || t == "❯" || t == "#" { return true }
        if t.hasPrefix("$ ") || t.hasPrefix("% ") || t.hasPrefix("❯ ") { return true }
        // Generic: prompt chars at end after optional path
        if let last = t.last, last == "$" || last == "#" || last == "%" || last == "❯" {
            // Check if there's a prompt-like prefix before it
            if t.contains("@") || t.contains("~") || t.hasPrefix("[") { return true }
        }
        return false
    }

    private func isCommandEcho(_ line: String) -> Bool {
        // Fallback heuristic ONLY — do NOT expand this list.
        // Final solution: PTY input/output correlation (input → echo → output).
        // Until PTY correlation is wired, keep this minimal to avoid precision>recall drift.
        // Example: `grep ERROR application.log` should not have ERROR in red
        // NOTE: `docker logs xxx` and `echo "2026-... ERROR"` are edge cases this heuristic
        // cannot distinguish; PTY correlation will solve them.
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        let shellVerbs = ["echo ", "grep ", "cat ", "ping ", "ls ", "docker ", "kubectl ", "ps ", "curl ", "wget ", "ssh ", "scp ", "sftp ", "vim ", "nano ", "less ", "tail ", "head ", "awk ", "sed "]
        for verb in shellVerbs {
            if lower.hasPrefix(verb) && !hasTimestamp(line) {
                return true
            }
        }
        // Also: if line is exactly the prompt + command, it's echo
        if line.contains("#") && line.contains("echo") { return true }
        return false
    }

    private func isContinuation(_ line: String) -> Bool {
        // Stack trace lines are indented and start with "at " or "    at " or have no timestamp
        if line.hasPrefix("    at ") || line.hasPrefix("\tat ") || line.hasPrefix("at ") { return true }
        if line.hasPrefix(" ") || line.hasPrefix("\t") {
            // Indented line after a log is likely continuation
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("at ") || trimmed.hasPrefix("Caused by:") || trimmed.hasPrefix("...") { return true }
            // If previous was log and this line has no strong signature but is indented, treat as continuation
            if !hasStrongSignature(line) && line.first?.isWhitespace == true {
                return true
            }
        }
        return false
    }

    // MARK: - Byte scanner (hot path, no regex) — zero-copy via String.utf8

    private func byteScannerStrongMatch(_ line: String) -> Bool? {
        // Returns nil if inconclusive (need regex), true/false if strong match found
        // Check for strong log prefixes without regex — ultra fast, no allocations
        let utf8 = line.utf8
        guard let first = utf8.first else { return false }
        // Syslog PRI: starts with '<' and digit
        if first == UInt8(ascii: "<") {
            var idx = utf8.index(after: utf8.startIndex)
            var digitCount = 0
            while idx != utf8.endIndex, digitCount < 4, utf8[idx] >= UInt8(ascii: "0"), utf8[idx] <= UInt8(ascii: "9") {
                digitCount += 1; idx = utf8.index(after: idx)
            }
            if idx != utf8.endIndex, utf8[idx] == UInt8(ascii: ">") { return true }
        }
        // Timestamp: starts with digit
        if first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9") {
            // Check for 4 digits + - or / prefix (YYYY- or YYYY/)
            if line.count >= 5 {
                let scalars = line.unicodeScalars
                var sIdx = scalars.startIndex
                var isYear = true
                for _ in 0..<4 {
                    guard sIdx != scalars.endIndex, scalars[sIdx].value >= 48, scalars[sIdx].value <= 57 else { isYear = false; break }
                    sIdx = scalars.index(after: sIdx)
                }
                if isYear, sIdx != scalars.endIndex, (scalars[sIdx] == "-" || scalars[sIdx] == "/") {
                    // Has timestamp prefix — check for level nearby without allocating lowercased copy
                    // Case-insensitive search via range(options: .caseInsensitive) avoids String allocation
                    let levels = [" info ", " error ", " warn", " debug", " trace", " alert", " crit", " fatal", " notice", " emerg", "[error]", "[warn]", "[info]"]
                    for lvl in levels {
                        if line.range(of: lvl, options: .caseInsensitive) != nil { return true }
                    }
                    if line.range(of: "[error]", options: .caseInsensitive) != nil { return true }
                    if line.range(of: "[warn]", options: .caseInsensitive) != nil { return true }
                    // If has timestamp + IP, it's log
                    let r = NSRange(line.startIndex..., in: line)
                    if Self.ipRegex.firstMatch(in: line, range: r) != nil { return true }
                    // Otherwise timestamp alone not enough (precision > recall)
                    return false
                }
            }
        }
        // BSD timestamp: Jan, Feb, Mar, etc. at start (3-char month)
        if line.count >= 3 {
            let prefix3 = line.prefix(3)
            let bsdMonths: Set<String> = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            if bsdMonths.contains(String(prefix3)) { return true }
        }
        // Nginx etc. -> fallback regex
        return nil
    }

    // Cached — was recompiled per call via range(of: regex)
    private static let timeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\d{2}:\d{2}:\d{2}"#)
    }()
    private static let ipRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\d+\.\d+\.\d+\.\d+"#)
    }()

    private func hasTimestamp(_ line: String) -> Bool {
        if line.contains("2026-") || line.contains("2026/") { return true }
        if line.contains(":") {
            let r = NSRange(line.startIndex..., in: line)
            if Self.timeRegex.firstMatch(in: line, range: r) != nil { return true }
        }
        return false
    }

    // MARK: - Strong signature via cached regex (fallback)

    private func hasStrongSignature(_ line: String) -> Bool {
        let r = NSRange(line.startIndex..., in: line)
        // 1. Timestamp + Level (strongest)
        if LogPatterns.timestampRegexStrong.firstMatch(in: line, range: r) != nil {
            // Need level nearby
            if LogPatterns.levelAtStartRegex.firstMatch(in: line, range: r) != nil { return true }
            // Or level anywhere after timestamp
            let lower = line.lowercased()
            if lower.contains(" info ") || lower.contains(" error ") || lower.contains(" warn") || lower.contains(" debug") { return true }
            if lower.contains("[error]") || lower.contains("[warn]") { return true }
        }
        // 2. ISO8601 + Level
        if LogPatterns.iso8601Regex.firstMatch(in: line, range: r) != nil { return true }
        // 3. Syslog PRI
        if line.hasPrefix("<"), let end = line.firstIndex(of: ">"), line.distance(from: line.startIndex, to: end) < 5 {
            return true
        }
        // 4. Nginx: 2026/08/27 [error]
        if LogPatterns.nginxRegex.firstMatch(in: line, range: r) != nil { return true }
        // 5. Java: [main] INFO or 2026-08-27 ... [main] INFO
        if LogPatterns.javaRegex.firstMatch(in: line, range: r) != nil { return true }
        // 6. Bracketed level at start or after timestamp
        if LogPatterns.bracketedLevel.regex.firstMatch(in: line, range: r) != nil {
            // Only if line looks like log (has timestamp or PRI)
            if hasTimestamp(line) { return true }
        }
        // 7. level=xxx (docker/k8s structured)
        if LogPatterns.dockerKV.regex.firstMatch(in: line, range: r) != nil { return true }
        return false
    }
}

// MARK: - LogPatterns strong regex extensions
extension LogPatterns {
    static let timestampRegexStrong: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}"#)
    }()
    static let iso8601Regex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?"#)
    }()
    static let nginxRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} \[(?:emerg|alert|crit|error|warn|notice|info|debug)\]"#, options: [.caseInsensitive])
    }()
    static let javaRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\[\w+(?:[-_]\w+)*\] (?:INFO|ERROR|WARN|DEBUG|TRACE)"#, options: [.caseInsensitive])
    }()
}
