import Foundation
import SwiftData
import Testing
@testable import Bonk

/// Covers the automatic recovery that runs after a wipe is detected.
///
/// On 2026-09-23 and again on 2026-09-29 the production store was found
/// emptied. Both times `StoreHealthGuard` froze the scene and refused to
/// restore, on the stated grounds that restoring "would overwrite the crime
/// scene" — but the scene is copied into its own `INCIDENT-*` directory
/// first, so that refusal is what turned a recoverable event into the loss of
/// every host. Recovery is now automatic; these tests pin the rule that makes
/// it safe, which is that only a snapshot that is BOTH intact and non-empty
/// may be promoted.
///
/// Without the "non-empty" rule, a wipe that happens to also produce an empty
/// snapshot would be silently promoted over good history.
///
/// All fixtures live in throwaway directories. No test reads or writes the
/// live store.
@Suite("Store Restore Recovery")
struct StoreRestoreRecoveryTests {
    private static let productionSchema = Schema([
        HostItem.self, UserPreferences.self, Credential.self, HostGroup.self,
        AIConversationRecord.self, AIMessageRecord.self, AIProviderRecord.self,
        Snippet.self, PortForward.self, JumpHost.self, InlineSuggestionRecord.self,
        SSHBackendProfile.self, TriggerRule.self,
        LogProfile.self, LogPatternRow.self,
    ])

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonk-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a real, valid SwiftData store at `<root>/<day>/default.store`
    /// holding `hosts` host rows — the same shape a daily snapshot has.
    @discardableResult
    private static func writeSnapshot(in root: URL, day: String, hosts: Int) throws -> URL {
        let dayDir = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let storeURL = dayDir.appendingPathComponent("default.store")
        let config = ModelConfiguration("snapshot", schema: productionSchema, url: storeURL)
        let container = try ModelContainer(for: productionSchema, configurations: [config])
        if hosts > 0 {
            let context = ModelContext(container)
            for index in 0..<hosts {
                context.insert(HostItem(
                    name: "host-\(index)",
                    host: "192.0.2.\(index + 1)",
                    port: 22,
                    username: "root",
                    authType: .password
                ))
            }
            try context.save()
        }
        return storeURL
    }

    /// Newest-first ordering is the whole point: a fresher snapshot with data
    /// must win over an older one.
    @Test("Newest snapshot holding data is chosen")
    func newestWithDataWins() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(in: root, day: "20260901", hosts: 3)
        let expected = try Self.writeSnapshot(in: root, day: "20260905", hosts: 7)

        let chosen = StoreBackupManager.newestRestorableSnapshot(in: root)
        #expect(chosen == expected)
    }

    /// The dangerous case: the newest snapshot is itself empty. Promoting it
    /// would overwrite nothing useful and leave production empty, so the
    /// search must fall through to the newest snapshot that has hosts.
    @Test("An empty newer snapshot is skipped in favour of an older populated one")
    func emptyNewerSnapshotIsSkipped() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try Self.writeSnapshot(in: root, day: "20260901", hosts: 5)
        _ = try Self.writeSnapshot(in: root, day: "20260909", hosts: 0)

        let chosen = StoreBackupManager.newestRestorableSnapshot(in: root)
        #expect(chosen == good, "promoting the empty snapshot would have destroyed the only copy")
    }

    /// A truncated or garbage file must never be promoted, even when it is the
    /// newest — that is how a recoverable incident becomes permanent loss.
    @Test("A corrupt snapshot is skipped")
    func corruptSnapshotIsSkipped() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try Self.writeSnapshot(in: root, day: "20260901", hosts: 4)

        let corruptDir = root.appendingPathComponent("20260909")
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        try Data("not a sqlite database at all".utf8)
            .write(to: corruptDir.appendingPathComponent("default.store"))

        #expect(StoreBackupManager.newestRestorableSnapshot(in: root) == good)
    }

    /// Nothing qualifies: the caller must be able to tell "no restore" from
    /// "restored", so it can leave the live store alone and say so.
    @Test("No snapshot qualifies when every candidate is empty")
    func noQualifyingSnapshotReturnsNil() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeSnapshot(in: root, day: "20260901", hosts: 0)
        try Self.writeSnapshot(in: root, day: "20260902", hosts: 0)

        #expect(StoreBackupManager.newestRestorableSnapshot(in: root) == nil)
    }

    @Test("A missing backup directory returns nil")
    func missingDirectoryReturnsNil() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(StoreBackupManager.newestRestorableSnapshot(
            in: root.appendingPathComponent("does-not-exist")
        ) == nil)
    }

    /// Frozen incident scenes and archived wiped state live in the same
    /// directory. Neither is restorable history, and promoting either would
    /// resurrect the damage the guard just captured.
    @Test("Incident and archived directories are never promoted")
    func incidentAndArchivedDirectoriesAreIgnored() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try Self.writeSnapshot(in: root, day: "20260901", hosts: 6)
        // Both sort after "20260901" and both hold data, so a prefix check that
        // regressed would pick one of them.
        _ = try Self.writeSnapshot(in: root, day: "INCIDENT-20260929-225359", hosts: 9)
        _ = try Self.writeSnapshot(in: root, day: "RESTORED-FROM-20260929-231156", hosts: 9)

        #expect(StoreBackupManager.newestRestorableSnapshot(in: root) == good)
    }
}
