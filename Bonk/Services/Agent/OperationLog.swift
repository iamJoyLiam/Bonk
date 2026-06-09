import Foundation
import os.log

/// Records Agent mode operations for audit trail and potential rollback.
/// Keeps the last 50 operations in memory.
@MainActor
final class OperationLog {
    static let shared = OperationLog()

    private static let logger = Logger(subsystem: "com.bonk", category: "OperationLog")
    private static let maxEntries = 50

    private(set) var entries: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let command: String
        let output: String
        let success: Bool
    }

    private init() {}

    /// Record a command execution.
    func record(command: String, output: String, success: Bool) {
        let entry = Entry(
            timestamp: Date(),
            command: command,
            output: String(output.prefix(4000)),
            success: success
        )
        entries.append(entry)

        // Trim to max size
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }

        Self.logger.info("Recorded: \(success ? "OK" : "FAIL", privacy: .public)")
    }

    /// Clear all entries.
    func clear() {
        entries.removeAll()
    }

    /// Get the last N entries.
    func recent(_ count: Int = 10) -> [Entry] {
        Array(entries.suffix(count))
    }
}
