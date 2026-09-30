import Foundation
import os.log

/// What happened, in a form you can read six months from now.
///
/// The 2026-09-29 investigation burned a night of archaeology: reading a frozen
/// SQLite file byte by byte to work out which schema had gutted the store, when
/// it happened, and how much data was lost. That was only possible because the
/// 22:53 capture happened to exist. Nothing recorded *why* it existed, or what
/// the app did about it.
///
/// So recovery now writes a record. The invariant: **a restore must always be
/// able to explain itself.** A snapshot that silently reappears looks identical
/// to a bug that never happened.
enum StoreIncidentRecord {
    private static let logger = Logger(subsystem: "com.bonk.app", category: "Store")

    struct Entry {
        var timestamp: Date
        var trigger: String
        var pid: Int32
        var bundleIdentifier: String
        var appVersion: String
        var buildVersion: String
        /// `schema_version` pragma of the damaged store, if it could be read.
        var damagedSchemaVersion: Int?
        var damagedHostCount: Int?
        /// `store_last_host_count` — the last count this app itself recorded.
        var expectedHostCount: Int?
        var quarantinedTo: String?
        var restoredFrom: String?
        /// Wall-clock gap between the restored snapshot's day and now, i.e. the
        /// most data a restore can possibly have lost.
        var dataLossWindowHours: Double?
    }

    static func record(_ entry: Entry) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: entry.timestamp)

        let lines = [
            "timestamp=\(formatter.string(from: entry.timestamp))",
            "trigger=\(entry.trigger)",
            "pid=\(entry.pid)",
            "bundle=\(entry.bundleIdentifier)",
            "app_version=\(entry.appVersion)",
            "build_version=\(entry.buildVersion)",
            "damaged_schema_version=\(entry.damagedSchemaVersion.map(String.init) ?? "unreadable")",
            "damaged_hosts=\(entry.damagedHostCount.map(String.init) ?? "unreadable")",
            "expected_hosts=\(entry.expectedHostCount.map(String.init) ?? "unrecorded")",
            "quarantined_to=\(entry.quarantinedTo ?? "none")",
            "restored_from=\(entry.restoredFrom ?? "nothing-restorable")",
            "data_loss_window_hours=\(entry.dataLossWindowHours.map { String(format: "%.2f", $0) } ?? "unknown")",
        ]

        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let dir = support.appendingPathComponent("Bonk-Backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("INCIDENT-RECORD.log")
        let text = lines.joined(separator: "\n") + "\n"
        // Append, never replace: the whole point is the history.
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: Data(("--- " + stamp + " ---\n" + text).utf8))
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        logger.fault("Store incident recorded: \(lines.joined(separator: " "), privacy: .public)")
    }

    /// Best-effort app identity. A missing bundle is not worth failing over:
    /// the record is still useful without it.
    static func appVersion() -> (short: String, build: String) {
        let info = Bundle.main.infoDictionary
        return (
            info?["CFBundleShortVersionString"] as? String ?? "unknown",
            info?["CFBundleVersion"] as? String ?? "unknown"
        )
    }
}
