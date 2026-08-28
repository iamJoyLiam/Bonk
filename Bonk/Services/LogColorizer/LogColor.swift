//
//  LogColor.swift
//  Bonk
//

import SwiftUI
import AppKit

enum LogColor {

    // MARK: - TrueColor

    /// "#RRGGBB" → "38;2;R;G;B"
    static func ansi(for hex: String) -> String {
        let c = Color(hex: hex)
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return "38;2;\(Int(ns.redComponent * 255));\(Int(ns.greenComponent * 255));\(Int(ns.blueComponent * 255))"
    }

    /// "38;2;R;G;B" 或 "#RRGGBB" → "#RRGGBB"（规范大写）
    static func hex(for ansiCode: String) -> String {
        let t = ansiCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#"), t.count == 7 { return t.uppercased() }
        if t.hasPrefix("38;2;") {
            let p = t.split(separator: ";").compactMap { Int($0) }
            if p.count >= 5 {
                return String(format: "#%02X%02X%02X", p[2], p[3], p[4])
            }
        }
        // 256/基础色 → 近似映射为可见色，避免返回空
        return color(for: t).hexString?.uppercased() ?? "#FF3B30"
    }

    /// ansiCode → SwiftUI Color（支持 38;2 / #hex / 基础码）
    static func color(for ansiCode: String) -> Color {
        let t = ansiCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("38;2;") {
            let p = t.split(separator: ";").compactMap { Int($0) }
            if p.count >= 5 {
                return Color(red: Double(p[2]) / 255, green: Double(p[3]) / 255, blue: Double(p[4]) / 255)
            }
        }
        if t.hasPrefix("#") { return Color(hex: t) }
        switch t {
        case "1;41;97": return Color.red // emerg/alert 白字红底 → 展示用红
        case "1;91":    return Color.red.opacity(0.95)
        case "1;31":    return .red
        case "1;33":    return .yellow
        case "1;34":    return .blue
        case "1;32":    return .green
        case "1;35":    return .purple
        case "2;32":    return .green.opacity(0.8)
        case "2;36":    return .cyan
        case "2;35":    return .purple.opacity(0.8)
        case "2;33":    return .yellow.opacity(0.9)
        case "2":       return .gray
        case "90":      return .gray
        default:        return .gray
        }
    }

    static func nsColor(for ansiCode: String) -> NSColor {
        NSColor(color(for: ansiCode))
    }

    // MARK: - Presets

    /// 6 常用 + 1 自定义 占位
    static let palette: [String] = ["#FF3B30", "#FF9500", "#FFCC02", "#34C759", "#007AFF", "#AF52DE"]

    static let presetRows: [(title: String, pattern: String, ansi: String, testLine: String)] = [
        ("Emerg",      "(?<![A-Za-z0-9_\\-])(?:EMERG(?:ENCY)?|PANIC)(?![A-Za-z0-9_\\-])", "1;41;97", "2026-08-27 10:00:00 EMERG panic 192.168.1.1"),
        ("Alert",      "(?<![A-Za-z0-9_\\-])ALERT(?![A-Za-z0-9_\\-])",                       "1;41;97", "2026-08-27 10:00:00 ALERT 192.168.1.1"),
        ("Crit",       "(?<![A-Za-z0-9_\\-])(?:CRIT(?:ICAL)?)(?![A-Za-z0-9_\\-])",           "1;91",    "2026-08-27 10:00:00 CRIT 192.168.1.1 hello"),
        ("Fatal",      "(?<![A-Za-z0-9_\\-])FATAL(?![A-Za-z0-9_\\-])",                       "1;91",    "2026-08-27 10:00:00 FATAL 192.168.1.1"),
        ("Error",      "(?<![A-Za-z0-9_\\-])(?:ERR(?:OR)?)(?![A-Za-z0-9_\\-])",              "1;31",    "2026-08-27 10:00:00 ERROR 192.168.1.1 hello"),
        ("Fail",       "(?<![A-Za-z0-9_\\-])(?:FAIL(?:ED)?|FAILURE)(?![A-Za-z0-9_\\-])",     "1;31",    "2026-08-27 10:00:00 FAIL 192.168.1.1"),
        ("Warn",       "(?<![A-Za-z0-9_\\-])(?:WARN(?:ING)?)(?![A-Za-z0-9_\\-])",            "1;33",    "2026-08-27 10:00:00 WARN hello 192.168.1.1"),
        ("Notice",     "(?<![A-Za-z0-9_\\-])NOTICE(?![A-Za-z0-9_\\-])",                      "1;32",    "2026-08-27 10:00:00 NOTICE hello"),
        ("Info",       "(?<![A-Za-z0-9_\\-])(?:INFO(?:RMATIONAL)?)(?![A-Za-z0-9_\\-])",      "1;34",    "2026-08-27 10:00:00 INFO hello 192.168.1.1"),
        ("Debug",      "(?<![A-Za-z0-9_\\-])(?:DEBUG|TRACE)(?![A-Za-z0-9_\\-])",             "2",       "2026-08-27 10:00:00 DEBUG trace"),
        ("IP",         "\\b(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\b", "38;2;0;199;190", "2026-08-27 10:00:00 INFO 192.168.1.1"),
        ("时间戳",      "\\d{4}[-/]\\d{2}[-/]\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?",     "2;32",    "2026-08-27 10:00:00 hello"),
        ("JSON level", "\"(?:level|severity)\"\\s*:\\s*\"[^\"]+\"",                        "1;35",    "{\"level\":\"error\",\"msg\":\"boom\"}"),
        ("Logfmt",     "\\blevel=(?:error|warn|info|debug|trace|fatal|emerg|alert|crit)\\b", "38;2;255;149;0", "level=error msg=boom"),
        ("自定义",      "",                                                                   "",       "2026-08-27 10:00:00 INFO hello 192.168.1.1"),
    ]
}
