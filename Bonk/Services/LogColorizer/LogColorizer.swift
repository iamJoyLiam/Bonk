//
//  LogColorizer.swift
//  Bonk
//
//  Field-level log colorization engine.
//  Scans each line for specific patterns (level keywords, IPs, timestamps, PIDs)
//  and wraps ONLY the matched spans with ANSI SGR codes.
//  Never colors the whole line — only the fields that match.
//

import Foundation

enum LogColorizer {

    // MARK: - Public API

    /// Colorize a chunk of terminal output text, field by field.
    static func colorize(_ text: String) -> String {
        guard LogColorizerConfig.isEnabled else { return text }

        // Fast path: skip chunks with no log-like content
        guard mightContainLogs(text) else { return text }

        // Process line-by-line
        var result = ""
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[lineStart..<lineEnd])
            result += colorizeLine(line)
            if lineEnd < text.endIndex {
                result += "\n"
                lineStart = text.index(after: lineEnd)
            } else {
                lineStart = lineEnd
            }
        }
        return result
    }

    // MARK: - Line Processing

    private static func colorizeLine(_ line: String) -> String {
        // Skip empty lines
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return line }

        // Skip lines that already contain ANSI escape sequences (server-colored output)
        if hasANSI(line) { return line }

        // Skip shell prompts and cursor control
        if isShellNoise(line) { return line }

        // Collect all (range, ansiCode, priority) tuples from all pattern matches
        var annotations: [(range: NSRange, code: String, priority: Int)] = []

        let fullRange = NSRange(line.startIndex..., in: line)

        // 1. Syslog PRI: <134> → color the PRI tag itself
        if let (severity, endIdx) = SyslogPRI.extract(from: line) {
            let priEnd = line.utf16.distance(from: line.startIndex, to: endIdx)
            let priRange = NSRange(location: 0, length: priEnd)
            annotations.append((priRange, severity.ansiCode, 1))
        }

        // 2. Scan all field patterns
        for pattern in LogPatterns.allPatterns {
            let matches = pattern.regex.matches(in: line, options: [], range: fullRange)
            for match in matches {
                annotations.append((match.range, pattern.ansiCode, pattern.priority))
            }
        }

        // If no annotations, return original
        if annotations.isEmpty { return line }

        // Deduplicate: for overlapping ranges, keep lowest priority (highest importance)
        let merged = mergeAnnotations(annotations)

        // Apply ANSI wrapping in reverse order to preserve indices
        return applyAnnotations(to: line, annotations: merged)
    }

    // MARK: - Annotation Merging

    /// For overlapping ranges, keep the one with lowest priority number.
    /// Non-overlapping ranges are all kept.
    private static func mergeAnnotations(_ annotations: [(range: NSRange, code: String, priority: Int)]) -> [(range: NSRange, code: String)] {
        // Sort by location, then by priority
        let sorted = annotations.sorted { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            return a.priority < b.priority
        }

        var result: [(range: NSRange, code: String)] = []
        var lastEnd = -1

        for ann in sorted {
            // Skip if this range overlaps with a higher-priority (already added) annotation
            if ann.range.location < lastEnd { continue }
            result.append((ann.range, ann.code))
            lastEnd = NSMaxRange(ann.range)
        }

        return result
    }

    // MARK: - ANSI Application

    /// Wrap matched ranges with ANSI escape codes. Applied in reverse to preserve indices.
    private static func applyAnnotations(to line: String, annotations: [(range: NSRange, code: String)]) -> String {
        guard !annotations.isEmpty else { return line }

        let nsLine = line as NSString
        let mutable = NSMutableString(string: line)

        // Apply in reverse order so earlier indices aren't shifted
        for ann in annotations.reversed() {
            let original = nsLine.substring(with: ann.range)
            let wrapped = "\u{1B}[\(ann.code)m\(original)\u{1B}[0m"
            mutable.replaceCharacters(in: ann.range, with: wrapped)
        }

        return mutable as String
    }

    // MARK: - Detection Helpers

    /// Quick heuristic: does this chunk look like it might contain log output?
    private static func mightContainLogs(_ text: String) -> Bool {
        let sample = String(text.prefix(300))

        // syslog PRI
        if sample.hasPrefix("<") { return true }

        // Known keywords
        let kw = ["ERROR", "WARN", "INFO", "DEBUG", "FATAL", "CRIT", "EMERG",
                   "NOTICE", "FAILED", "TIMEOUT", "level=", "TRACE"]
        for k in kw {
            if sample.localizedCaseInsensitiveContains(k) { return true }
        }

        // ISO timestamp
        if sample.range(of: "\\d{4}[-/]\\d{2}[-/]\\d{2}[T ]\\d{2}:\\d{2}", options: .regularExpression) != nil {
            return true
        }

        // Chinese date: 7月 24
        if sample.range(of: "\\d{1,2}月", options: .regularExpression) != nil {
            return true
        }

        // BSD syslog timestamp
        if sample.range(of: "[A-Z][a-z]{2}\\s+\\d{1,2}\\s+\\d{2}:\\d{2}", options: .regularExpression) != nil {
            return true
        }

        // Bracketed level
        if sample.range(of: "\\[(?:error|warn|info|debug|fatal|crit|notice|emerg)\\]", options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Check if text contains ANY escape sequences.
    /// Any ESC byte disqualifies the line: CSI, OSC, DCS, and half-split
    /// sequences across chunk boundaries must all be preserved verbatim.
    /// (Checking only complete CSI sequences let the colorizer inject SGR
    /// codes into OSC strings / split escapes, corrupting SwiftTerm's
    /// escape-state machine and rendering garbage like "1;34m1.2.3.4m".)
    private static func hasANSI(_ text: String) -> Bool {
        text.contains("\u{1B}")
    }

    /// Skip shell prompts, cursor control, tab completion noise.
    private static func isShellNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        // Prompt patterns
        if t.range(of: #"^(?:\$\s|>\s|#\s|[%>]\s)"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^\w+@[\w.-]+:\S*\s*[#$>]\s*$"#, options: .regularExpression) != nil { return true }
        return false
    }
}
