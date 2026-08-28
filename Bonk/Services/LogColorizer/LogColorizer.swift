//
//  LogColorizer.swift
//  Bonk
//
//  Field-level log colorization engine.
//

import Foundation

enum LogColorizer {

    // MARK: - Public API

    /// Legacy overload (no host)
    static func colorize(_ text: String) -> String { colorize(text, host: nil) }

    /// Host-aware entry; snapshot taken once per chunk, prev isolated per chunk
    static func colorize(_ text: String, host: HostItem?) -> String {
        guard LogColorizerConfig.isEnabled else { return text }
        let patterns = LogSnapshot.patterns(for: host)
        return colorize(text, patterns: patterns)
    }

    /// Patterns-direct entry (for worker cache isolation)
    static func colorize(_ text: String, patterns: [LogFieldPattern]) -> String {
        guard LogColorizerConfig.isEnabled else { return text }

        let nsText = text as NSString
        let length = nsText.length
        var result = ""
        result.reserveCapacity(text.utf8.count + 32)
        var searchLoc = 0
        var previousWasLog = false
        let classifier = LogClassifier()

        while searchLoc < length {
            let range = nsText.range(of: "\n", options: [], range: NSRange(location: searchLoc, length: length - searchLoc))
            if range.location == NSNotFound {
                let tailStart = String.Index(utf16Offset: searchLoc, in: text)
                result += String(text[tailStart...])
                break
            }
            let lineStart = String.Index(utf16Offset: searchLoc, in: text)
            let lineEnd = String.Index(utf16Offset: range.location, in: text)
            var line = String(text[lineStart..<lineEnd])
            let hasCR = line.hasSuffix("\r")
            if hasCR { line.removeLast() }
            let colored = colorizeLine(line, patterns: patterns, classifier: classifier, previousWasLog: &previousWasLog)
            result += colored
            result += hasCR ? "\r\n" : "\n"
            searchLoc = range.location + 1
        }
        return result
    }

    // MARK: - Line Processing

    // MARK: - Line Processing

    private static func colorizeLine(_ line: String, patterns: [LogFieldPattern], classifier: LogClassifier, previousWasLog: inout Bool) -> String {
        if line.isEmpty { previousWasLog = false; return line }
        if hasANSI(line) { previousWasLog = false; return line }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { previousWasLog = false; return line }
        if isShellNoise(line) { previousWasLog = false; return line }

        let classification = classifier.classify(line, previousWasLog: previousWasLog)
        switch classification {
        case .notLog:
            previousWasLog = false
            return line
        case .log, .continuation:
            previousWasLog = true
        }

        let spans = ZeroCopyScanner().scan(line: line, patterns: patterns)
        if spans.isEmpty { return line }
        let merged = ZeroCopyScanner.Dedup.toANSIRanges(spans)
        return applyAnnotations(to: line, annotations: merged)
    }

    /// Standalone line colorize for preview
    static func colorizeLineStandalone(_ line: String, patterns: [LogFieldPattern]) -> String {
        if line.isEmpty || hasANSI(line) || line.trimmingCharacters(in: .whitespaces).isEmpty || isShellNoise(line) { return line }
        let classifier = LogClassifier()
        let c = classifier.classify(line, previousWasLog: false)
        guard c == .log || c == .continuation else { return line }
        let spans = ZeroCopyScanner().scan(line: line, patterns: patterns)
        if spans.isEmpty { return line }
        return applyAnnotations(to: line, annotations: ZeroCopyScanner.Dedup.toANSIRanges(spans))
    }

    // MARK: - ANSI Application

    private static func applyAnnotations(to line: String, annotations: [(range: NSRange, code: String)]) -> String {
        guard !annotations.isEmpty else { return line }
        let nsLine = line as NSString
        let mutable = NSMutableString(string: line)
        for ann in annotations.reversed() {
            let original = nsLine.substring(with: ann.range)
            let wrapped = "\u{1B}[\(ann.code)m\(original)\u{1B}[0m"
            mutable.replaceCharacters(in: ann.range, with: wrapped)
        }
        return mutable as String
    }

    // MARK: - Helpers

    private static func hasANSI(_ text: String) -> Bool { text.contains("\u{1B}") }

    private static let shellNoiseRegex1: NSRegularExpression? = try? NSRegularExpression(pattern: #"^(?:\$\s|>\s|#\s|[%>]\s)"#)
    private static let shellNoiseRegex2: NSRegularExpression? = try? NSRegularExpression(pattern: #"^\w+@[\w.-]+:\S*\s*[#$>]\s*$"#)

    private static func isShellNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let r1 = shellNoiseRegex1, r1.firstMatch(in: trimmed, range: range) != nil { return true }
        if let r2 = shellNoiseRegex2, r2.firstMatch(in: trimmed, range: range) != nil { return true }
        return false
    }
}
