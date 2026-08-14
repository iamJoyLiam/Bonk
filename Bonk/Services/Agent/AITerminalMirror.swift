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
    static func format(
        command: String,
        status: AgentMessage.CommandStatus,
        duration: TimeInterval?,
        output: String?,
        hostName: String?
    ) -> String {
        var lines: [String] = ["\r\n"]
        lines.append("\u{1B}[1;36m[AI·\(hostName ?? "agent")]\u{1B}[0m")
        lines.append("\u{1B}[1;32m$ \(command)\u{1B}[0m")

        let statusColor: String
        switch status {
        case .success: statusColor = "32"
        case .failed: statusColor = "31"
        case .blocked: statusColor = "90"
        case .skipped: statusColor = "33"
        }
        let icon = switch status {
        case .success: "✓"
        case .failed: "✗"
        case .blocked: "⛔"
        case .skipped: "⏭"
        }
        let durationText = duration.map { String(format: " %.1fs", $0) } ?? ""
        lines.append("\u{1B}[\(statusColor)m\(icon)\(durationText)\u{1B}[0m")

        if let output, !output.isEmpty {
            let excerpt = String(output.prefix(800))
            lines.append(excerpt)
        }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }
}
