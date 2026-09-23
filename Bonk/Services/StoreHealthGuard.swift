import Foundation
import os.log
import SQLite3

/// Startup forensics for the file-backed store.
///
/// Forensics-first policy: on anomaly, FREEZE the scene and record evidence.
/// Never auto-restore — restoring would overwrite the crime scene and make
/// the root cause permanently uncatchable. Recovery stays a deliberate
/// manual step from a dated snapshot under Bonk-Backups.
///
/// Background: the store was once found structurally rewritten in place
/// (same inode; entity rows and Z_MAX zeroed; history purged; schema_version
/// jumped ~55; sqlite_master byte-identical afterwards). No in-app deleter,
/// reset routine, manual migration, or second container exists; root cause
/// unproven. This guard exists to capture the NEXT incident intact.
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
        Log.app.fault("Store wipe detected (marker had \(marker, privacy: .public) hosts, live has 0) — scene frozen at \(incidentDir.lastPathComponent, privacy: .public), live files untouched")
    }

    /// Record the current host count on graceful backgrounding.
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
