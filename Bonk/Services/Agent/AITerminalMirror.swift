import Foundation

/// Mirrors AI agent command executions into the visible terminal.
/// The engine posts a lightweight notification; the terminal view layer feeds
/// the formatted lines into the active pane (display-only, no echo back).
enum AITerminalMirror {
    static let commandKey = "command"
    static let statusKey = "status"
    static let durationKey = "duration"
    static let outputKey = "output"
    static let hostKey = "host"

    static func post(
        command: String,
        status: AgentMessage.CommandStatus,
        duration: TimeInterval?,
        output: String?,
        hostName: String?
    ) {
        var userInfo: [AnyHashable: Any] = [
            commandKey: command,
            statusKey: status.rawValue,
            hostKey: hostName ?? "",
        ]
        if let duration { userInfo[durationKey] = duration }
        if let output, !output.isEmpty { userInfo[outputKey] = output }
        NotificationCenter.default.post(name: .aiAgentCommandExecuted, object: nil, userInfo: userInfo)
    }

    /// Format a mirror block for the terminal, with ANSI colors and a trimmed
    /// output excerpt so a huge command result can't flood the screen.
    ///
    /// Renders as a bounded block (Codex-style): header rule, command, muted
    /// status line, indented output with a `│` gutter, and a status footer
    /// rule — so agent output stays visually distinct from the user's own
    /// shell output in the shared terminal stream.
    static func format(
        command: String,
        status: AgentMessage.CommandStatus,
        duration: TimeInterval?,
        output: String?,
        hostName: String?
    ) -> String {
        let host = hostName ?? "agent"
        let icon = Self.icon(for: status)
        let statusColor = Self.color(for: status)
        let durationText = duration.map { String(format: "%.1fs", $0) } ?? ""

        var lines: [String] = ["\r\n"]
        lines.append(rule("── [AI·\(host)]", color: "1;36"))

        lines.append("\u{1B}[1;32m$ \(command)\u{1B}[0m")

        if let output, !output.isEmpty {
            let outputLines = Self.cleanOutputLines(output)
            let total = outputLines.count
            let shown = Array(outputLines.prefix(maxOutputLines))
            let omitted = total - shown.count

            var meta = durationText.isEmpty
                ? "\(total) 行输出"
                : "\(durationText) · \(total) 行输出"
            lines.append("\u{1B}[90m\(icon) \(meta)\u{1B}[0m")

            for line in shown {
                lines.append("\u{1B}[36m  │\u{1B}[0m \(line)")
            }
            if omitted > 0 {
                lines.append("\u{1B}[90m  ⋯ 还有 \(omitted) 行输出被省略\u{1B}[0m")
            }
        } else {
            let meta = durationText.isEmpty ? "no output" : "\(durationText) · no output"
            lines.append("\u{1B}[90m\(icon) \(meta)\u{1B}[0m")
        }

        let word = Self.footerWord(for: status)
        lines.append(rule("── \(icon) \(word)\(durationText.isEmpty ? "" : " · \(durationText)")", color: statusColor))
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// Cap on output lines mirrored into the terminal.
    private static let maxOutputLines = 15

    /// ANSI-strip, split, and trim output into displayable lines.
    private static func cleanOutputLines(_ output: String) -> [String] {
        let stripped = stripANSI(output)
        var lines = stripped
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    /// Rule line: colored text left-aligned, padded with ─ to a fixed width.
    private static func rule(_ text: String, color: String) -> String {
        let pad = max(2, lineWidth - text.count - 1)
        return "\u{1B}[\(color)m\(text) \(String(repeating: "─", count: pad))\u{1B}[0m"
    }

    private static let lineWidth = 60

    private static func icon(for status: AgentMessage.CommandStatus) -> String {
        switch status {
        case .success: "✓"
        case .failed: "✗"
        case .blocked: "⛔"
        case .skipped: "⏭"
        }
    }

    private static func color(for status: AgentMessage.CommandStatus) -> String {
        switch status {
        case .success: "32"
        case .failed: "31"
        case .blocked: "90"
        case .skipped: "33"
        }
    }

    private static func footerWord(for status: AgentMessage.CommandStatus) -> String {
        switch status {
        case .success: "完成"
        case .failed: "失败"
        case .blocked: "已阻止"
        case .skipped: "已跳过"
        }
    }

    private static func stripANSI(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)"#,
                with: "",
                options: .regularExpression
            )
    }
}
