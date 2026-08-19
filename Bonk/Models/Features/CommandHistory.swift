//
//  CommandHistory.swift
//  Bonk
//

import Foundation

/// A recorded command execution with timing and exit code.
struct CommandRecord: Identifiable, Codable {
    let id: UUID
    let command: String
    /// Stable host scope. Nil keeps backward compatibility with old history.
    let hostKey: String?
    let startTime: Date
    var endTime: Date?
    var exitCode: Int?
    var output: String?

    init(command: String, hostKey: String? = nil, startTime: Date = Date()) {
        self.id = UUID()
        self.command = command
        self.hostKey = hostKey
        self.startTime = startTime
    }

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
        guard let exitCode else { return false }
        return exitCode == 0
    }
}

/// Global command history shared across all terminal sessions.
/// Persists to UserDefaults with automatic deduplication.
@Observable @MainActor
final class GlobalCommandHistory {
    static let shared = GlobalCommandHistory()

    private let storageKey = "globalCommandHistory"
    private let maxHistory = 200

    var commands: [CommandRecord] = []
    var currentCommand: CommandRecord?

    private init() {
        load()
    }

    // MARK: - Public API

    /// Record a command start.
    func commandStarted(_ command: String, hostKey: String? = nil) {
        // Finish any previous command
        if var current = currentCommand {
            current.endTime = Date()
            appendWithDedup(current)
        }

        currentCommand = CommandRecord(command: command, hostKey: hostKey)
    }

    /// Record a command completion.
    func commandFinished(exitCode: Int) {
        currentCommand?.endTime = Date()
        currentCommand?.exitCode = exitCode

        if let cmd = currentCommand {
            appendWithDedup(cmd)
        }
        currentCommand = nil
    }

    /// Clear all history.
    func clear() {
        commands = []
        currentCommand = nil
        save()
    }

    /// Delete a single record.
    func delete(_ record: CommandRecord) {
        commands.removeAll { $0.id == record.id }
        save()
    }

    // MARK: - Deduplication

    /// Append command, removing any older duplicate (same command text).
    private func appendWithDedup(_ record: CommandRecord) {
        // Remove older entries with same command text within same host scope.
        commands.removeAll {
            $0.command == record.command && $0.hostKey == record.hostKey
        }
        // Add new entry at the end (most recent)
        commands.append(record)
        // Trim to max
        if commands.count > maxHistory {
            commands = Array(commands.suffix(maxHistory))
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CommandRecord].self, from: data) else { return }
        commands = decoded
    }
}

/// Tracks command history for a terminal session (legacy, per-session).
/// Kept for backward compatibility but should migrate to GlobalCommandHistory.
@Observable @MainActor
final class CommandHistory {
    var commands: [CommandRecord] = []
    var currentCommand: CommandRecord?

    let maxHistory = 100

    func commandStarted(_ command: String) {
        if var current = currentCommand {
            current.endTime = Date()
            commands.append(current)
        }
        currentCommand = CommandRecord(command: command)
        if commands.count > maxHistory {
            commands = Array(commands.suffix(maxHistory))
        }
    }

    func commandFinished(exitCode: Int) {
        currentCommand?.endTime = Date()
        currentCommand?.exitCode = exitCode
        if let cmd = currentCommand {
            commands.append(cmd)
        }
        currentCommand = nil
    }

    func clear() {
        commands = []
        currentCommand = nil
    }
}
