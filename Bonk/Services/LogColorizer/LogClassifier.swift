//
//  LogClassifier.swift
//  Bonk
//

import Foundation

enum LogClassification {
    case log
    case notLog
    case continuation // multiline stack trace / indented continuation
}

final class LogClassifier: Sendable {

    // MARK: - Public
    func classify(_ line: String, previousWasLog: Bool) -> LogClassification {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .notLog }

        // 0. Shell prompt / echo
        if isShellPrompt(line) { return .notLog }
        if PTYEchoTracker.shared.isEcho(line) { return .notLog }
        if isCommandEcho(line) { return .notLog }

        // 0.5 continuation
        if previousWasLog, isContinuation(line) { return .continuation }

        // 1. Byte scanner
        if let strong = byteScannerStrongMatch(line) { return strong ? .log : .notLog }

        // 2.
        if hasStrongSignature(line) { return .log }

        return .notLog
    }

    // /  prev  false，
    func classify(_ line: String) -> LogClassification { classify(line, previousWasLog: false) }

    func isContinuationLine(_ line: String) -> Bool { isContinuation(line) }

    // MARK: - Shell prompt

    private func isShellPrompt(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") && t.contains("]#") { return true }
        if t.contains("@") && (t.contains(":$") || t.contains("~$") || t.contains("]#") || t.contains("~#")) { return true }
        if t == "$" || t == "%" || t == "❯" || t == "#" { return true }
        if t.hasPrefix("$ ") || t.hasPrefix("% ") || t.hasPrefix("❯ ") { return true }
        if let last = t.last, last == "$" || last == "#" || last == "%" || last == "❯" {
            if t.contains("@") || t.contains("~") || t.hasPrefix("[") { return true }
        }
        return false
    }

    private func isCommandEcho(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        let shellVerbs = ["echo ", "grep ", "cat ", "ping ", "ls ", "docker ", "kubectl ", "ps ", "curl ", "wget ", "ssh ", "scp ", "sftp ", "vim ", "nano ", "less ", "tail ", "head ", "awk ", "sed "]
        for verb in shellVerbs where lower.hasPrefix(verb) && !hasTimestamp(line) { return true }
        if line.contains("#") && line.contains("echo") { return true }
        return false
    }

    private func isContinuation(_ line: String) -> Bool {
        if line.hasPrefix("    at ") || line.hasPrefix("\tat ") || line.hasPrefix("at ") { return true }
        if line.hasPrefix(" ") || line.hasPrefix("\t") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("at ") || trimmed.hasPrefix("Caused by:") || trimmed.hasPrefix("...") { return true }
            if !hasStrongSignature(line) && line.first?.isWhitespace == true { return true }
        }
        return false
    }

    // MARK: - Byte scanner

    private func byteScannerStrongMatch(_ line: String) -> Bool? {
        let utf8 = line.utf8
        guard let first = utf8.first else { return false }
        if first == UInt8(ascii: "<") {
            var idx = utf8.index(after: utf8.startIndex)
            var digitCount = 0
            while idx != utf8.endIndex, digitCount < 4, utf8[idx] >= UInt8(ascii: "0"), utf8[idx] <= UInt8(ascii: "9") {
                digitCount += 1; idx = utf8.index(after: idx)
            }
            if idx != utf8.endIndex, utf8[idx] == UInt8(ascii: ">") { return true }
        }
        if first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9"), line.count >= 5 {
            let scalars = line.unicodeScalars
            var sIdx = scalars.startIndex
            var isYear = true
            for _ in 0..<4 {
                guard sIdx != scalars.endIndex, scalars[sIdx].value >= 48, scalars[sIdx].value <= 57 else { isYear = false; break }
                sIdx = scalars.index(after: sIdx)
            }
            if isYear, sIdx != scalars.endIndex, (scalars[sIdx] == "-" || scalars[sIdx] == "/") {
                let levels = [" info ", " error ", " warn", " debug", " trace", " alert", " crit", " fatal", " notice", " emerg", "[error]", "[warn]", "[info]"]
                for lvl in levels where line.range(of: lvl, options: .caseInsensitive) != nil { return true }
                let r = NSRange(line.startIndex..., in: line)
                if Self.ipRegex.firstMatch(in: line, range: r) != nil { return true }
                return false
            }
        }
        if line.count >= 3 {
            let p3 = String(line.prefix(3))
            if Self.bsdMonths.contains(p3) { return true }
        }
        return nil
    }

    private static let bsdMonths: Set<String> = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    private static let timeRegex: NSRegularExpression = { try! NSRegularExpression(pattern: #"\d{2}:\d{2}:\d{2}"#) }()
    private static let ipRegex: NSRegularExpression = { try! NSRegularExpression(pattern: #"\d+\.\d+\.\d+\.\d+"#) }()

    private func hasTimestamp(_ line: String) -> Bool {
        if line.contains("2026-") || line.contains("2026/") { return true }
        if line.contains(":") {
            let r = NSRange(line.startIndex..., in: line)
            if Self.timeRegex.firstMatch(in: line, range: r) != nil { return true }
        }
        return false
    }

    // MARK: - Strong signature

    private func hasStrongSignature(_ line: String) -> Bool {
        let r = NSRange(line.startIndex..., in: line)
        if LogPatterns.timestampRegexStrong.firstMatch(in: line, range: r) != nil {
            if LogPatterns.levelAtStartRegex.firstMatch(in: line, range: r) != nil { return true }
            let lower = line.lowercased()
            if lower.contains(" info ") || lower.contains(" error ") || lower.contains(" warn") || lower.contains(" debug") { return true }
            if lower.contains("[error]") || lower.contains("[warn]") { return true }
        }
        if LogPatterns.iso8601Regex.firstMatch(in: line, range: r) != nil { return true }
        if line.hasPrefix("<"), let end = line.firstIndex(of: ">"), line.distance(from: line.startIndex, to: end) < 5 { return true }
        if LogPatterns.nginxRegex.firstMatch(in: line, range: r) != nil { return true }
        if LogPatterns.javaRegex.firstMatch(in: line, range: r) != nil { return true }
        if LogPatterns.bracketedLevel.regex.firstMatch(in: line, range: r) != nil, hasTimestamp(line) { return true }
        if LogPatterns.dockerKV.regex.firstMatch(in: line, range: r) != nil { return true }
        return false
    }
}

// MARK: - LogPatterns strong regex extensions
extension LogPatterns {
    static let timestampRegexStrong: NSRegularExpression = { try! NSRegularExpression(pattern: #"\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}"#) }()
    static let iso8601Regex: NSRegularExpression = { try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?"#) }()
    static let nginxRegex: NSRegularExpression = { try! NSRegularExpression(pattern: #"\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} \[(?:emerg|alert|crit|error|warn|notice|info|debug)\]"#, options: [.caseInsensitive]) }()
    static let javaRegex: NSRegularExpression = { try! NSRegularExpression(pattern: #"\[\w+(?:[-_]\w+)*\] (?:INFO|ERROR|WARN|DEBUG|TRACE)"#, options: [.caseInsensitive]) }()
}
