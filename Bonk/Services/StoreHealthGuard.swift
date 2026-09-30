import Foundation
import os.log
import SQLite3

/// Startup forensics for the file-backed store.
///
/// Policy: on anomaly, FREEZE the scene, then RESTORE from the newest
/// snapshot that actually holds user data. The scene is copied into its own
/// `INCIDENT-*` directory first, so restoring the live file cannot destroy
/// evidence — a previous version refused to restore on the mistaken belief
/// that it would overwrite the scene, and that refusal is why the 2026-09-23
/// and 2026-09-29 wipes each cost every host. Restores are refused when the
/// candidate snapshot is corrupt or has no hosts.
///
/// Background: the store was found structurally rewritten in place (same
/// inode; entity rows and Z_MAX zeroed; history purged; schema_version
/// climbed; sqlite_master byte-identical afterwards), then repopulated with
/// nothing but the app's own seed data. No in-app deleter, reset routine,
/// manual migration, or second container exists; root cause unproven. This
/// guard exists to bound the damage of the next incident, not to prevent it.
enum StoreHealthGuard {
    static let lastHostCountKey = "store_last_host_count"
    /// Set when a wipe is detected; UI/diagnostics can surface it.
    static let wipeDetectedKey = "store_wipe_detected_at"
    private static let storeName = "default.store"
    private static let backupDirName = "Bonk-Backups"
    private static let incidentPrefix = "INCIDENT-"

    // Main-thread only (set from app init); the source itself is thread-safe.
    private static nonisolated(unsafe) var watchSource: DispatchSourceFileSystemObject?

    /// Run FIRST in app init, before the container opens. Detects a wipe and
    /// freezes evidence; never touches the live files.
    static func freezeIncidentIfWiped() {
        #if DEBUG
            return
        #endif
        let marker = UserDefaults.standard.integer(forKey: lastHostCountKey)
        guard marker > 0 else { return }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let liveURL = support.appendingPathComponent(storeName)
        let liveCount = rowCount(in: liveURL, table: "ZHOSTITEM") ?? 0
        guard liveCount == 0 else { return }

        let stamp: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: Date())
        }()
        let incidentId = UUID().uuidString
        let incidentDir = support
            .appendingPathComponent(backupDirName)
            .appendingPathComponent(incidentPrefix + stamp)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: incidentDir, withIntermediateDirectories: true)
        // Byte copies of the scene as found (db + wal + shm if present).
        // A WAL-mode database is inseparable from its -wal: committed rows
        // may live only there, so all three travel together.
        var walExists = false
        var shmExists = false
        for ext in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: liveURL.path + ext)
            if fileManager.fileExists(atPath: src.path) {
                if ext == "-wal" { walExists = true }
                if ext == "-shm" { shmExists = true }
                try? fileManager.copyItem(
                    at: src,
                    to: URL(fileURLWithPath: incidentDir.path + "/" + storeName + ext)
                )
            }
        }
        // Evidence ledger next to the frozen files. PID + timestamp + inode
        // align with lsof / fs_usage output after the fact.
        let attributes = try? fileManager.attributesOfItem(atPath: liveURL.path)
        let ledger = [
            "incident_id=\(incidentId)",
            "detected_at=\(stamp)",
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "process_name=\(ProcessInfo.processInfo.processName)",
            "database_path=\(liveURL.path)",
            "inode=\(attributes?[.systemFileNumber] as? UInt64 ?? 0)",
            "file_size=\(attributes?[.size] as? UInt64 ?? 0)",
            "marker_hosts=\(marker)",
            "journal_mode=\(pragmaText(in: liveURL, statement: "PRAGMA journal_mode") ?? "?")",
            "wal_exists=\(walExists)",
            "shm_exists=\(shmExists)",
            "schema_version=\(pragmaValue(in: liveURL, statement: "PRAGMA schema_version") ?? -1)",
            "user_version=\(pragmaValue(in: liveURL, statement: "PRAGMA user_version") ?? -1)",
            "integrity_check=\(pragmaText(in: liveURL, statement: "PRAGMA integrity_check") ?? "?")",
            "row_ZHOSTITEM=\(rowCount(in: liveURL, table: "ZHOSTITEM") ?? -1)",
            "row_ZHOSTGROUP=\(rowCount(in: liveURL, table: "ZHOSTGROUP") ?? -1)",
            "row_ZCREDENTIAL=\(rowCount(in: liveURL, table: "ZCREDENTIAL") ?? -1)",
            "row_ZUSERPREFERENCES=\(rowCount(in: liveURL, table: "ZUSERPREFERENCES") ?? -1)",
        ].joined(separator: "\n")
        try? ledger.write(to: incidentDir.appendingPathComponent("EVIDENCE.txt"), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(stamp, forKey: wipeDetectedKey)
        Log.app.fault("Store wipe detected (marker had \(marker, privacy: .public) hosts, live has 0) — scene frozen at \(incidentDir.lastPathComponent, privacy: .public)")
        // The scene is already copied above, so restoring the live file cannot
        // destroy evidence. Leaving production empty until a human notices is
        // what turns a recoverable incident into total loss — this ran on
        // 2026-09-23 and again on 2026-09-29, each time wiping every host.
        let restored = StoreBackupManager.restoreLatestKnownGood()
        if let restored {
            Log.app.notice("Store wipe recovered from \(restored, privacy: .public); wiped state preserved under \(incidentDir.lastPathComponent, privacy: .public)")
        }
        // A restore that leaves no trace looks exactly like a bug that never
        // happened. Record what was lost, from what, and over what window.
        let version = StoreIncidentRecord.appVersion()
        StoreIncidentRecord.record(.init(
            timestamp: Date(),
            trigger: "SCHEMA_INTEGRITY:hosts_zero",
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: version.short,
            buildVersion: version.build,
            damagedSchemaVersion: pragmaValue(in: liveURL, statement: "PRAGMA schema_version"),
            damagedHostCount: rowCount(in: liveURL, table: "ZHOSTITEM"),
            expectedHostCount: marker,
            quarantinedTo: incidentDir.lastPathComponent,
            restoredFrom: restored,
            dataLossWindowHours: restored.flatMap { hoursSince(day: $0) }
        ))
    }

    /// Age of a daily snapshot directory, which bounds how much a restore from
    /// it can have lost.
    private static func hoursSince(day: String) -> Double? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        guard let snapshotDate = formatter.date(from: day) else { return nil }
        return Date().timeIntervalSince(snapshotDate) / 3600
    }

    /// A recovery *heuristic*, not an authority.
    ///
    /// This is the last count the app saw on a clean path. It is recorded on
    /// terminate, so it misses crashes, `kill -9` and power loss, and it cannot
    /// distinguish "user deleted everything" from "the store was destroyed".
    /// Integrity is therefore decided by reading the store, never by trusting
    /// this number — it only decides whether a wipe is worth investigating.
    static func recordHostCount(_ count: Int) {
        UserDefaults.standard.set(count, forKey: lastHostCountKey)
    }

    /// Watch the live store file for external deletion/rename/revocation.
    static func startWatching() {
        #if DEBUG
            return
        #endif
        guard watchSource == nil,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let liveURL = support.appendingPathComponent(storeName)
        let fd = open(liveURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler {
            Log.app.fault("Store file event while running: \(source.data.rawValue, privacy: .public) — possible external interference")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }

    // MARK: - Private

    /// Raw SQLite row count without opening a SwiftData container.
    private static func rowCount(in url: URL, table: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        // Table may not exist on very old/foreign files — treat as unreadable, not zero.
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Raw SQLite integer pragma without opening a SwiftData container.
    private static func pragmaValue(in url: URL, statement: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Raw SQLite text pragma without opening a SwiftData container.
    private static func pragmaText(in url: URL, statement: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, statement, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}
