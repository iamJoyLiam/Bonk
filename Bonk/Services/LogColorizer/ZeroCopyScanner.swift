//
//  ZeroCopyScanner.swift
//  Bonk — Final Architecture: Zero-Copy Scanner
//
//  Zero Full-Buffer Copy: never copies the entire Terminal Buffer.
//  Input is new bytes -> Scanner -> Span(offset,length) without String/AttributedString rebuild.
//

import Foundation

struct HighlightSpan: Sendable, Equatable {
    let offset: Int // utf16 offset (NSRange location)
    let length: Int
    let ansiCode: String
    let priority: Int
    init(offset: Int, length: Int, ansiCode: String, priority: Int = 50) {
        self.offset = offset; self.length = length; self.ansiCode = ansiCode; self.priority = priority
    }
}

final class ZeroCopyScanner: @unchecked Sendable {
    // Token definitions only — LogPatterns defines field rules, not line classification.
    // Scanner is only called after LogClassifier says LOG.

    func scan(line: String) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        let fullRange = NSRange(line.startIndex..., in: line)
        for pattern in LogPatterns.allPatterns {
            let matches = pattern.regex.matches(in: line, options: [], range: fullRange)
            for m in matches {
                spans.append(HighlightSpan(offset: m.range.location, length: m.range.length, ansiCode: pattern.ansiCode, priority: pattern.priority))
            }
        }
        if let (sev, endIdx) = SyslogPRI.extract(from: line) {
            let len = line.utf16.distance(from: line.startIndex, to: endIdx)
            spans.append(HighlightSpan(offset: 0, length: len, ansiCode: sev.ansiCode, priority: 1))
        }
        return Dedup.merge(spans)
    }

    // Shared merge ensures single dedup logic for LogColorizer & overlay
    enum Dedup {
        static func merge(_ spans: [HighlightSpan]) -> [HighlightSpan] {
            let sorted = spans.sorted {
                if $0.offset != $1.offset { return $0.offset < $1.offset }
                return $0.priority < $1.priority // lowest priority (most important) first
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
        static func toANSIRanges(_ spans: [HighlightSpan]) -> [(range: NSRange, code: String)] {
            spans.map { (NSRange(location: $0.offset, length: $0.length), $0.ansiCode) }
        }
    }
}
