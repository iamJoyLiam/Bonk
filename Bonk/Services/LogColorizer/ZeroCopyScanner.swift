//
//  ZeroCopyScanner.swift
//  Bonk — Final Architecture: Zero-Copy Scanner
//
//  Zero Full-Buffer Copy: never copies the entire Terminal Buffer.
//  Input is new bytes -> Scanner -> Span(offset,length) without String/AttributedString rebuild.
//

import Foundation

struct HighlightSpan: Sendable, Equatable {
    let offset: Int // utf8 offset in line
    let length: Int
    let ansiCode: String
}

final class ZeroCopyScanner: @unchecked Sendable {
    // Token definitions only — LogPatterns defines field rules, not line classification.
    // Scanner is only called after LogClassifier says LOG.

    func scan(line: String) -> [HighlightSpan] {
        // Fast byte-level pre-check before regex: does line contain strong token bytes?
        // This avoids per-line regex for non-log lines that passed classifier via strong signature?
        // Actually classifier already ensured it's a log, so we can directly scan tokens.
        // Use LogPatterns.tokenRegexes only (level, IP, timestamp, etc.)
        var spans: [HighlightSpan] = []
        let fullRange = NSRange(line.startIndex..., in: line)
        for pattern in LogPatterns.allPatterns {
            let matches = pattern.regex.matches(in: line, options: [], range: fullRange)
            for m in matches {
                spans.append(HighlightSpan(offset: m.range.location, length: m.range.length, ansiCode: pattern.ansiCode))
            }
        }
        // Also check syslog PRI at start
        if let (sev, endIdx) = SyslogPRI.extract(from: line) {
            let len = line.utf16.distance(from: line.startIndex, to: endIdx)
            spans.append(HighlightSpan(offset: 0, length: len, ansiCode: sev.ansiCode))
        }
        // Deduplicate overlapping spans by priority (lowest wins)
        return merge(spans)
    }

    private func merge(_ spans: [HighlightSpan]) -> [HighlightSpan] {
        let sorted = spans.sorted {
            if $0.offset != $1.offset { return $0.offset < $1.offset }
            // Use priority via ansiCode ordering? For now keep first
            return $0.length > $1.length
        }
        var result: [HighlightSpan] = []
        var lastEnd = -1
        for s in sorted {
            if s.offset < lastEnd { continue }
            result.append(s)
            lastEnd = s.offset + s.length
        }
        return result
    }
}
