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

        // Use NSString for LF search: Swift's `firstIndex(of: "\n" as Character)`
        // treats "\r\n" as a single grapheme cluster, so it misses the LF
        // inside CRLF and leaves CRLF-terminated log lines uncolored (tail path).
        // NSString operates on UTF-16 and finds the LF scalar correctly.
        let nsText = text as NSString
        let length = nsText.length
        var result = ""
        result.reserveCapacity(text.utf8.count + 32)
        var searchLoc = 0
        while searchLoc < length {
            let range = nsText.range(of: "\n", options: [], range: NSRange(location: searchLoc, length: length - searchLoc))
            if range.location == NSNotFound {
                // Tail without terminating \n — leave raw to avoid injecting SGR
                // into a half-split escape sequence; it will be colored when
                // the next chunk completes the line.
                let tailStart = String.Index(utf16Offset: searchLoc, in: text)
                result += String(text[tailStart...])
                break
            }
            let lineStart = String.Index(utf16Offset: searchLoc, in: text)
            let lineEnd = String.Index(utf16Offset: range.location, in: text)
            var line = String(text[lineStart..<lineEnd]) // excludes \n, includes \r if CRLF
            let hasCR = line.hasSuffix("\r")
            if hasCR { line.removeLast() }
            result += colorizeLine(line)
            result += hasCR ? "\r\n" : "\n"
            searchLoc = range.location + 1
        }
        return result
    }

    // MARK: - Classifier (two-stage pipeline: LogClassifier -> LogTokenizer)
    nonisolated(unsafe) private static let classifier = LogClassifier()

    // MARK: - Line Processing

    private static func colorizeLine(_ line: String) -> String {
        // Fast-path: empty or ANSI — no trimming needed first.
        if line.isEmpty { return line }
        if hasANSI(line) { return line }
        // Skip empty/whitespace-only lines — avoid double trimming (isShellNoise trims again).
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }

        // Skip shell prompts and cursor control (highest priority, precision > recall)
        if isShellNoise(line) { return line }

        // Two-stage pipeline: LogClassifier decides LOG vs NOT_LOG (strong signatures, shell echo, multiline)
        // LogPatterns are token definitions only — not used to decide if a line is a log.
        let classification = classifier.classify(line)
        guard classification == .log || classification == .continuation else { return line }

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
        let sorted = annotations.sorted { patternA, patternB in
            if patternA.range.location != patternB.range.location { return patternA.range.location < patternB.range.location }
            return patternA.priority < patternB.priority
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

    /// Check if text contains ANY escape sequences.
    private static func hasANSI(_ text: String) -> Bool {
        text.contains("\u{1B}")
    }

    // Cached shell-noise regexes — previously recompiled per line.
    private static let shellNoiseRegex1: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(?:\$\s|>\s|#\s|[%>]\s)"#
    )
    private static let shellNoiseRegex2: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\w+@[\w.-]+:\S*\s*[#$>]\s*$"#
    )

    /// Skip shell prompts, cursor control, tab completion noise.
    private static func isShellNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let r1 = shellNoiseRegex1, r1.firstMatch(in: trimmed, range: range) != nil { return true }
        if let r2 = shellNoiseRegex2, r2.firstMatch(in: trimmed, range: range) != nil { return true }
        return false
    }
}
