import SwiftUI

/// Lightweight shell syntax highlighter for AI-rendered code blocks.
/// Priority order: comments > strings > variables > numbers > leading command.
/// Painted ranges never overlap, so a `#` comment stays muted even when it
/// contains quotes or `$VAR` tokens.
enum ShellSyntaxHighlighter {
    static func highlight(_ line: String, fontSize: CGFloat = 12) -> AttributedString {
        var attributed = AttributedString(line)
        attributed.font = .system(size: fontSize, design: .monospaced)
        attributed.foregroundColor = .primary

        var painted: [NSRange] = []

        paint(commentRanges(in: line), color: .secondary, into: &attributed, painted: &painted)
        paint(stringRanges(in: line), color: .orange, into: &attributed, painted: &painted)
        paint(variableRanges(in: line), color: .purple, into: &attributed, painted: &painted)
        paint(numberRanges(in: line), color: .teal, into: &attributed, painted: &painted)
        paint(leadingCommandRange(in: line), color: .green, into: &attributed, painted: &painted)

        return attributed
    }

    private static func paint(
        _ nsRanges: [NSRange],
        color: Color,
        into attributed: inout AttributedString,
        painted: inout [NSRange]
    ) {
        for nsRange in nsRanges where nsRange.length > 0 {
            guard !painted.contains(where: { NSIntersectionRange($0, nsRange).length > 0 }) else { continue }
            guard let range = Range(nsRange, in: attributed) else { continue }
            attributed[range].foregroundColor = color
            painted.append(nsRange)
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map(\.range)
    }

    private static func commentRanges(in line: String) -> [NSRange] {
        matches(#"#[^\n]*"#, in: line)
    }

    private static func stringRanges(in line: String) -> [NSRange] {
        matches(#"'[^']*'|"[^"]*"|`[^`]*`"#, in: line)
    }

    private static func variableRanges(in line: String) -> [NSRange] {
        matches(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, in: line)
    }

    private static func numberRanges(in line: String) -> [NSRange] {
        matches(#"\b\d+\b"#, in: line)
    }

    private static func leadingCommandRange(in line: String) -> [NSRange] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first,
              commandKeywords.contains(String(first)),
              let range = trimmed.range(of: first)
        else { return [] }
        return [NSRange(range, in: line)]
    }

    private static let commandKeywords: Set<String> = [
        "cd", "ls", "cat", "pwd", "mkdir", "rm", "cp", "mv", "touch", "ln",
        "chmod", "chown", "sudo", "su", "docker", "docker-compose", "kubectl",
        "systemctl", "service", "journalctl", "tail", "head", "grep", "awk",
        "sed", "find", "ps", "top", "htop", "df", "du", "free", "uname",
        "whoami", "which", "echo", "export", "source", "kill", "killall",
        "tar", "gzip", "gunzip", "wget", "curl", "git", "pip", "pip3",
        "npm", "yarn", "pnpm", "brew", "apt", "apt-get", "yum", "dnf",
        "ip", "ifconfig", "ping", "ssh", "scp", "rsync", "mount", "umount",
        "crontab", "uptime", "hostname", "date", "file", "stat", "tree",
        "man", "less", "more", "vi", "vim", "nano", "clear", "history",
        "alias", "unset", "read", "exit", "sleep", "time", "xargs", "sort",
        "uniq", "wc", "cut", "tr", "basename", "dirname", "realpath", "env",
        "nproc", "system_profiler", "sh", "bash", "zsh", "python", "python3",
        "node", "ruby", "go", "rustc", "cargo", "make", "cmake", "swift",
    ]
}
