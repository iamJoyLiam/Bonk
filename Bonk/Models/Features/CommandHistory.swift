//
//  CommandHistory.swift
//  Bonk
//

import Foundation

/// A recorded command execution with timing and exit code.
struct CommandRecord: Identifiable {
    let id = UUID()
    let command: String
    let startTime: Date
    var endTime: Date?
    var exitCode: Int?
    var output: String?

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    var durationFormatted: String {
        guard let duration else { return "..." }
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        }
    }

    var isSuccess: Bool {
        guard let exitCode else { return nil != nil }
        return exitCode == 0
    }
}

/// Tracks command history for a terminal session.
@Observable @MainActor
final class CommandHistory {
    var commands: [CommandRecord] = []
    var currentCommand: CommandRecord?

    /// Maximum number of commands to keep.
    let maxHistory = 100

    /// Record a command start.
    func commandStarted(_ command: String) {
        // Finish any previous command
        if var current = currentCommand {
            current.endTime = Date()
            commands.append(current)
        }

        currentCommand = CommandRecord(
            command: command,
            startTime: Date()
        )

        // Trim history
        if commands.count > maxHistory {
            commands = Array(commands.suffix(maxHistory))
        }
    }

    /// Record a command completion.
    func commandFinished(exitCode: Int) {
        currentCommand?.endTime = Date()
        currentCommand?.exitCode = exitCode

        if let cmd = currentCommand {
            commands.append(cmd)
        }
        currentCommand = nil
    }

    /// Clear all history.
    func clear() {
        commands = []
        currentCommand = nil
    }
}
