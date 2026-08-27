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
        let bytes = Array(line.utf8)
        if let strong = byteScannerStrongMatch(bytes) {
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
        // If the line looks like a shell command that was echoed (user input),
        // we treat it as NOT_LOG to avoid coloring the command itself.
        // Example: `grep ERROR application.log` should not have ERROR in red
        // Heuristic: line starts with common shell verbs and contains no timestamp
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

    // MARK: - Byte scanner (hot path, no regex)

    private func byteScannerStrongMatch(_ bytes: [UInt8]) -> Bool? {
        // Returns nil if inconclusive (need regex), true/false if strong match found
        // Check for strong log prefixes without regex — ultra fast
        if bytes.isEmpty { return false }
        let first = bytes[0]
        // Syslog PRI: starts with '<' and digit
        if first == UInt8(ascii: "<") {
            // Check if next chars are digits and then '>'
            var i = 1
            while i < bytes.count && i < 5 && bytes[i] >= UInt8(ascii: "0") && bytes[i] <= UInt8(ascii: "9") { i += 1 }
            if i < bytes.count && bytes[i] == UInt8(ascii: ">") { return true }
        }
        // Timestamp: starts with digit '2' (for 2026-) or digit for BSD (Jan, Feb)
        if first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9") {
            // Check for "2026-" or "2026/" prefix (4 digits + - or /)
            if bytes.count >= 5 {
                let isYear = bytes[0] >= UInt8(ascii: "0") && bytes[0] <= UInt8(ascii: "9") &&
                             bytes[1] >= UInt8(ascii: "0") && bytes[1] <= UInt8(ascii: "9") &&
                             bytes[2] >= UInt8(ascii: "0") && bytes[2] <= UInt8(ascii: "9") &&
                             bytes[3] >= UInt8(ascii: "0") && bytes[3] <= UInt8(ascii: "9") &&
                             (bytes[4] == UInt8(ascii: "-") || bytes[4] == UInt8(ascii: "/"))
                if isYear {
                    // Need to check if after timestamp there's a level nearby (within 40 chars)
                    // For byte scanner, just check if line contains level keyword after timestamp
                    // We do a quick scan for level substrings without regex (case-insensitive)
                    let line = String(bytes: bytes, encoding: .utf8) ?? ""
                    let lower = line.lowercased()
                    let levels = [" info ", " error ", " warn", " debug", " trace", " alert", " crit", " fatal", " notice", " emerg", "[error]", "[warn]", "[info]"]
                    for lvl in levels {
                        if lower.contains(lvl) { return true }
                    }
                    // Also check for bracketed level like [error]
                    if lower.contains("[error]") || lower.contains("[warn]") { return true }
                    // Has timestamp but no level — still log (e.g., nginx access log)
                    // But for precision, require level or bracket or IP
                    // If it has timestamp + IP, it's log
                    if lower.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil { return true }
                    // Otherwise, timestamp alone is not enough for precision > recall
                    return false
                }
            }
            // Check for "2026/08/27" nginx style
            // Already covered by isYear above
        }
        // BSD timestamp: Jan, Feb, Mar, etc. at start
        if bytes.count >= 3 {
            let prefix3 = String(bytes: Array(bytes.prefix(3)), encoding: .utf8) ?? ""
            let bsdMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            if bsdMonths.contains(prefix3) { return true }
        }
        // Nginx: check for " [error]" or " [warn]" pattern
        // This will be caught by hasStrongSignature fallback, so return nil to let regex handle
        return nil
    }

    private func hasTimestamp(_ line: String) -> Bool {
        // Quick check without regex: does line contain "2026-" or "2026/" or ":" with time?
        return line.contains("2026-") || line.contains("2026/") || line.contains(":") && line.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil
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
