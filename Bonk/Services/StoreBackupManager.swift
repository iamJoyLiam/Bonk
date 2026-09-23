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
