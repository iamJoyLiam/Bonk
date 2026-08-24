//
//  LogPatterns.swift
//  Bonk
//
//  Field-level log pattern library.
//  Each rule defines a regex + color for a specific field (level keyword, IP, timestamp, etc).
//  No whole-line coloring — only matched fields get colored.
//

import Foundation

// MARK: - Pattern Definition

/// A single field-level colorization rule.
struct LogFieldPattern: Sendable {
    let name: String
    let regex: NSRegularExpression
    /// ANSI SGR parameter: "31"=red, "33"=yellow, "36"=cyan, etc.
    let ansiCode: String
    /// Priority for dedup — when multiple patterns match the same span, lowest wins.
    let priority: Int

    init(_ name: String, _ pattern: String, _ ansiCode: String, _ priority: Int = 50) {
        self.name = name
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            self.regex = regex
        } else {
            assertionFailure("Invalid log pattern \(name): \(pattern)")
            // Fallback to never-match to keep app alive in Release (a^ is always valid)
            // swiftlint:disable:next force_try
            self.regex = try! NSRegularExpression(pattern: "a^", options: [])
        }
        self.ansiCode = ansiCode
        self.priority = priority
    }
}

// MARK: - Syslog Severity → ANSI

enum SyslogSeverity: Int {
    case emergency = 0, alert = 1, critical = 2, error = 3
    case warning = 4, notice = 5, info = 6, debug = 7

    var ansiCode: String {
        switch self {
        case .emergency, .alert:  return "1;41;97"  // bold white on red bg
        case .critical:           return "1;91"      // bold red
        case .error:              return "31"        // red
        case .warning:            return "33"        // yellow
        case .notice:             return "32"        // green
        case .info:               return "34"        // blue
        case .debug:              return "90"        // gray
        }
    }
}

// MARK: - Pattern Collections

enum LogPatterns {

    // MARK: - Level Keywords (colored wherever found)
    //
    // Bold variants for critical levels — visible on both light and dark backgrounds.

    static let levelKeywords: [LogFieldPattern] = [
        LogFieldPattern("emerg", "\\b(?:EMERG(?:ENCY)?|PANIC)\\b", "1;41;97", 10),
        LogFieldPattern("alert", "\\bALERT\\b", "1;41;97", 11),
        LogFieldPattern("crit", "\\b(?:CRIT(?:ICAL)?)\\b", "1;91", 12),
        LogFieldPattern("fatal", "\\bFATAL\\b", "1;91", 13),
        LogFieldPattern("error", "\\b(?:ERR(?:OR)?)\\b", "1;31", 14),
        LogFieldPattern("fail", "\\b(?:FAIL(?:ED)?|FAILURE)\\b", "1;31", 15),
        LogFieldPattern("timeout", "\\bTIMEOUT\\b", "1;31", 16),
        LogFieldPattern("refused", "\\bREFUSED\\b", "1;31", 17),
        LogFieldPattern("warn", "\\b(?:WARN(?:ING)?)\\b", "1;33", 20),
        LogFieldPattern("notice", "\\bNOTICE\\b", "1;32", 25),
        LogFieldPattern("success", "\\b(?:SUCCESS|COMPLETED|CONNECTED)\\b", "1;32", 26),
        LogFieldPattern("info", "\\b(?:INFO(?:RMATIONAL)?)\\b", "1;34", 30),
        LogFieldPattern("debug", "\\b(?:DEBUG|TRACE)\\b", "2", 35),
    ]

    // MARK: - Inline Fields
    //
    // Color palette — each field type gets a distinct hue:
    //   IP       → bold blue (1;34)   — structured data, high visibility
    //   Timestamp → dim green (2;32)  — metadata, recedes but readable
    //   PID      → dim cyan (2;36)    — metadata, distinct from timestamp
    //   Thread   → dim magenta (2;35) — distinct from PID

    static let ipAddresses = LogFieldPattern(
        // Strict IPv4: every octet validated 0-255 (previous \d{1,3} matched
        // invalid addresses like 192.168.8.290 and colored them).
        "ip",
        "\\b(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\b",
        "1;34", 50
    )

    static let macAddresses = LogFieldPattern(
        "mac", "\\b[0-9A-Fa-f]{1,2}(?::[0-9A-Fa-f]{1,2}){5}\\b", "1;34", 51
    )

    /// Timestamps — anywhere in line, with optional milliseconds
    /// Matches: 2026-07-24 15:59:59.956, 2026-07-24T15:59:59, Jul 24 15:59:59, etc.
    static let timestamps = LogFieldPattern(
        "timestamp",
        "\\d{4}[-/]\\d{2}[-/]\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?",
        "2;32", 60
    )

    /// Chinese date: 7月 24 16:07:53
    static let chineseTimestamp = LogFieldPattern(
        "chinese_ts", "\\d{1,2}月\\s*\\d{1,2}\\s+\\d{2}:\\d{2}:\\d{2}", "2;32", 60
    )

    /// BSD syslog timestamp: Aug 20 13:47:08 (must exist in the quick
    /// signature too, or the prefilter and the patterns disagree).
    static let bsdTimestamp = LogFieldPattern(
        "bsd_ts", "[A-Z][a-z]{2}\\s+\\d{1,2}\\s+\\d{2}:\\d{2}(?::\\d{2})?", "2;32", 60
    )

    /// Thread info: pool-5-thread-1, worker-3 — must start with letter, end with digit.
    /// (The bare word "main" is intentionally NOT matched: it colored any
    /// ordinary line containing the word "main".)
    static let threadInfo = LogFieldPattern(
        "thread", "\\b[a-zA-Z][\\w]*(?:-\\d+)+\\b", "2;35", 62
    )

    /// UUID: 5dad9bfa-a9da-4b50-8dc4-ae6f9dc634e0
    static let uuid = LogFieldPattern(
        "uuid", "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b", "2;33", 55
    )

    /// Process/PID: nginx[1234], sshd[28471]
    static let processPID = LogFieldPattern(
        "pid", "\\b\\w+\\[\\d+\\]", "2;36", 61
    )

    /// Brackets containing level-like content: [error], [WARN], [notice]
    static let bracketedLevel = LogFieldPattern(
        "bracket_level", "\\[(?:emerg|alert|crit(?:ical)?|err(?:or)?|warn(?:ing)?|notice|info(?:rmational)?|debug|trace|fatal)\\]", "1;35", 40
    )

    /// Docker/k8s level=xxx
    static let dockerKV = LogFieldPattern(
        "docker_level", "level=(?:emerg|alert|crit|error|warn|notice|info|debug)", "1;35", 41
    )

    /// All patterns in scan order
    static let allPatterns: [LogFieldPattern] = [
        bracketedLevel,
        dockerKV,
        uuid,
        ipAddresses,
        macAddresses,
        timestamps,
        chineseTimestamp,
        bsdTimestamp,
        processPID,
        threadInfo,
    ] + levelKeywords

    /// ONE regex that recognizes ANY signature a log line can carry.
    /// A line that fails this scan cannot match any pattern above, so it is
    /// returned untouched after a single regex pass (the hot path for
    /// non-log output). Kept in sync with `allPatterns` by hand.
    static let quickSignatureRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: """
        (?:\\b(?:EMERG(?:ENCY)?|PANIC|ALERT|CRIT(?:ICAL)?|FATAL|ERR(?:OR)?|FAIL(?:ED)?|FAILURE|TIMEOUT|REFUSED|WARN(?:ING)?|NOTICE|SUCCESS|COMPLETED|CONNECTED|INFO(?:RMATIONAL)?|DEBUG|TRACE)\\b
        |\\b(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\b
        |\\b[0-9A-Fa-f]{1,2}(?::[0-9A-Fa-f]{1,2}){5}\\b
        |\\d{4}[-/]\\d{2}[-/]\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?
        |\\d{1,2}月\\s*\\d{1,2}\\s+\\d{2}:\\d{2}:\\d{2}
        |[A-Z][a-z]{2}\\s+\\d{1,2}\\s+\\d{2}:\\d{2}(?::\\d{2})?
        |\\b\\w+\\[\\d+\\]
        |\\b[a-zA-Z][\\w]*(?:-\\d+)+\\b
        |\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b
        |\\[(?:emerg|alert|crit(?:ical)?|err(?:or)?|warn(?:ing)?|notice|info(?:rmational)?|debug|trace|fatal)\\]
        |level=(?:emerg|alert|crit|error|warn|notice|info|debug)
        |<\\d{1,3}>
        """,
        options: [.caseInsensitive]
    )
}

// MARK: - Syslog PRI Helpers

enum SyslogPRI {

    /// Extract severity from `<PRI>` prefix. Returns (severity, lengthOfMatch).
    static func extract(from text: String) -> (severity: SyslogSeverity, end: String.Index)? {
        guard text.hasPrefix("<"), let endIdx = text.firstIndex(of: ">"),
              endIdx != text.startIndex else { return nil }

        let priStr = String(text[text.index(after: text.startIndex)..<endIdx])
        guard let pri = Int(priStr), pri >= 0, pri <= 191 else { return nil }
        let severity = SyslogSeverity(rawValue: pri % 8) ?? .info
        return (severity, text.index(after: endIdx))
    }
}
