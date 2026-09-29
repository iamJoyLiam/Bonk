import Foundation
import os.log
import SQLite3
import SwiftData

/// Daily consistent snapshot of the file-backed SwiftData store.
/// Forensics-first policy: this is a safety net only, never a substitute
/// for finding the root cause, and it never restores anything by itself.
///
/// A raw file copy is NOT a valid backup for a WAL-mode database: committed
/// rows may still sit in -wal, uncheckpointed. Snapshots are therefore taken
/// with `VACUUM INTO`, which produces a single-file, transactionally
/// consistent logical copy. Keeps the last 7 daily snapshots.

/// Daily rotating backup of the file-backed SwiftData store.
/// Insurance against store loss or corruption: keeps the last 7 daily
/// copies under Application Support/Bonk-Backups. Runs once per day,
/// after successful container init (so only healthy stores are kept).
enum StoreBackupManager {
    private static let backupDirName = "Bonk-Backups"
    private static let keepCount = 7
    private static let storeName = "default.store"
    private static let incidentDirPrefix = "INCIDENT-"
    private static let archivedDirPrefix = "RESTORED-"

    static func backupIfNeeded() {
        #if DEBUG
            // In-memory store: nothing on disk to back up.
            return
        #endif
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let storeURL = support.appendingPathComponent(storeName)
        guard fileManager.fileExists(atPath: storeURL.path) else { return }

        let dir = support.appendingPathComponent(backupDirName)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let day: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            return formatter.string(from: Date())
        }()
        let dayDir = dir.appendingPathComponent(day)
        // Already backed up today.
        guard !fileManager.fileExists(atPath: dayDir.path) else { return }
        // An emptied store must never rotate out good history (wipe, failed
        // migration, or user deleting everything). Fresh installs with no
        // backups yet still establish a baseline.
        if hasBackups(dir: dir), (try? hostCount()) == 0 {
            Log.app.error("Store backup skipped: host table is empty, keeping existing history")
            return
        }

        do {
            try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
            try snapshotLiveStore(to: dayDir.appendingPathComponent(storeName).path)
            prune(dir: dir)
            Log.app.info("Store snapshot written to \(dayDir.lastPathComponent, privacy: .public)")
        } catch {
            // Backup must never break launch.
            Log.app.error("Store snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Consistent logical snapshot via VACUUM INTO. Reads committed state
    /// (including WAL) into a single compacted file; no -wal/-shm needed.
    /// Runs at launch when the container is freshly opened and idle.
    /// The snapshot is verified with integrity_check before it is kept —
    /// a file is produced only if it is also a restorable one.
    private static func snapshotLiveStore(to destinationPath: String) throws {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreBackupError.noSupportDirectory
        }
        let liveURL = support.appendingPathComponent(storeName)
        var db: OpaquePointer?
        guard sqlite3_open_v2(liveURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw StoreBackupError.openFailed
        }
        defer { sqlite3_close(db) }
        let escaped = destinationPath.replacingOccurrences(of: "'", with: "''")
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "VACUUM INTO '\(escaped)'", -1, &stmt, nil) == SQLITE_OK, let stmt,
              sqlite3_step(stmt) == SQLITE_DONE
        else {
            throw StoreBackupError.snapshotFailed(String(cString: sqlite3_errmsg(db)))
        }
        // Verify the snapshot before keeping it (separate connection; the
        // deferred finalize above still owns the VACUUM statement).
        guard snapshotIsHealthy(at: destinationPath) else {
            try? FileManager.default.removeItem(atPath: destinationPath)
            throw StoreBackupError.snapshotCorrupt
        }
    }

    private static func snapshotIsHealthy(at path: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &stmt, nil) == SQLITE_OK, let stmt,
              sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0),
              String(cString: text) == "ok"
        else {
            return false
        }
        return true
    }

    /// Restore the newest snapshot that actually holds user data.
    ///
    /// Called by `StoreHealthGuard` right after it freezes the wiped scene into
    /// its own `INCIDENT-*` directory. That copy is the crime scene, so
    /// restoring the live file cannot destroy evidence.
    ///
    /// Never promotes a snapshot that is corrupt or has no hosts. Returns the
    /// restored snapshot's directory name, or nil when nothing qualifies.
    @discardableResult
    static func restoreLatestKnownGood() -> String? {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent(backupDirName)
        guard let source = newestRestorableSnapshot(in: dir) else {
            Log.app.fault("Store wipe detected but no snapshot held user data — left untouched for manual recovery")
            return nil
        }
        do {
            try install(source: source, support: support)
            let day = source.deletingLastPathComponent().lastPathComponent
            Log.app.fault("Store restored from snapshot \(day, privacy: .public) after a wipe was detected")
            return day
        } catch {
            Log.app.error("Store restore failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pure decision: which snapshot, if any, may be promoted into the live
    /// store. Newest-first; a candidate qualifies only when it is intact AND
    /// holds at least one host. `INCIDENT-*` and `RESTORED-*` are skipped:
    /// they hold frozen evidence and archived wiped state, never history.
    static func newestRestorableSnapshot(in dir: URL) -> URL? {
        let fileManager = FileManager.default
        guard let days = try? fileManager.contentsOfDirectory(atPath: dir.path)
            .filter({ !$0.hasPrefix(incidentDirPrefix) && !$0.hasPrefix(archivedDirPrefix) })
            .sorted(by: >)
        else { return nil }
        for day in days {
            let candidate = dir.appendingPathComponent(day).appendingPathComponent(storeName)
            guard fileManager.fileExists(atPath: candidate.path),
                  snapshotIsPromotable(at: candidate.path)
            else { continue }
            return candidate
        }
        return nil
    }

    /// Swap a snapshot into the live location. A WAL-mode database is
    /// inseparable from its -wal, so stale sidecars from the wiped store must
    /// go or SQLite replays them onto the restored file.
    private static func install(source: URL, support: URL) throws {
        let fileManager = FileManager.default
        let liveURL = support.appendingPathComponent(storeName)
        let staged = support.appendingPathComponent(storeName + ".restoring")
        try? fileManager.removeItem(at: staged)
        try fileManager.copyItem(at: source, to: staged)
        try? fileManager.removeItem(atPath: liveURL.path + "-wal")
        try? fileManager.removeItem(atPath: liveURL.path + "-shm")
        _ = try fileManager.replaceItemAt(liveURL, withItemAt: staged)
    }

    /// A snapshot may be promoted only if it is intact AND holds user data.
    /// Both facts are read over ONE connection: a second read-only open can hit
    /// SQLITE_BUSY while another reader holds the file, and treating "could not
    /// determine" as "not promotable" would silently skip the only good copy.
    private static func snapshotIsPromotable(at path: String) -> Bool {
        guard let hosts = snapshotHostCount(at: path), hosts > 0 else { return false }
        return true
    }

    /// Host count of a snapshot, or nil when unreadable or failing
    /// `integrity_check`. A busy timeout keeps a transient lock from reading as
    /// "no data" — that misread is what makes a safety net silently do nothing.
    private static func snapshotHostCount(at path: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        var integrity: OpaquePointer?
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &integrity, nil) == SQLITE_OK,
              let integrity,
              sqlite3_step(integrity) == SQLITE_ROW,
              let text = sqlite3_column_text(integrity, 0),
              String(cString: text) == "ok"
        else { return nil }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZHOSTITEM", -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private enum StoreBackupError: Error {
        case noSupportDirectory
        case openFailed
        case snapshotFailed(String)
        case snapshotCorrupt
    }

    private static func hasBackups(dir: URL) -> Bool {
        guard let days = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return !days.isEmpty
    }

    private static func hostCount() throws -> Int {
        let context = ModelContext(BonkApp.sharedModelContainer)
        return try context.fetchCount(FetchDescriptor<HostItem>())
    }

    private static func prune(dir: URL) {
        let fileManager = FileManager.default
        guard let days = try? fileManager.contentsOfDirectory(atPath: dir.path).sorted() else { return }
        for old in days.dropLast(keepCount) {
            try? fileManager.removeItem(at: dir.appendingPathComponent(old))
        }
    }
}
