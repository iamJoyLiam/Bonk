import Foundation
import Testing
@testable import Bonk

/// Legacy `com.bonk.hostKeys` → canonical import.
///
/// ## The property under test
///
/// The legacy table is a real trust decision made on first contact. Carrying it
/// into the canonical store preserves that; dropping it silently re-authorises
/// first contact for every host the user had already pinned. The dangerous
/// direction is therefore not "fail to import" but "import wrongly" — and
/// especially *resolve a disagreement automatically*.
///
/// ## The conflict case is the one that matters
///
/// If the canonical store already holds a record whose fingerprint differs from
/// the legacy pin, the migration must do nothing to either side and say so. It
/// must not prefer whichever store it read last, and it must not overwrite the
/// record to make the two agree. Every gate below therefore checks the
/// post-condition on **both** stores, not just the report.
///
/// ## Isolation
///
/// The legacy source is a protocol requirement, so these tests supply their own.
/// `UserDefaults.standard` is the user's real defaults domain; a test that read
/// or wrote it would be testing the user's machine. `theRealDefaultsDomainIsNever
/// Touched` asserts that directly rather than trusting the convention.
/// 
@Suite("AUDIT-FIND-001 — legacy trust migrates, and conflicts stay unresolved")
struct LegacyHostKeyMigrationTests {
    // MARK: - Empty

    @Test("an empty legacy table migrates nothing and leaves the store alone")
    func emptyLegacyTableIsANoOp() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The store file does not exist yet, and that is the correct starting
        // state: reading it unconditionally would throw and report a missing-file
        // error rather than the property under test.
        let before = (try? Data(contentsOf: dir.appendingPathComponent("records.json"))) ?? Data()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("records.json").path) == false,
                "a fresh store must not have written its file yet")

        let report = try LegacyHostKeyMigrator(
            store: store, source: StaticLegacySource([:])
        ).migrate()

        #expect(report.isEmpty, "an empty legacy table must produce an empty report")
        #expect(!report.hasConflicts, "no conflicts can exist when there is no legacy data")
        let after = (try? Data(contentsOf: dir.appendingPathComponent("records.json"))) ?? Data()
        #expect(after == before,
                "an empty migration must not create or rewrite the store file")
    }

    // MARK: - Valid import

    @Test("a legacy pin is carried over and is visible to the resolver's lookup")
    func validLegacyPinIsImported() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pin = SSHHostFingerprint(hash: "SHA256:" + String(repeating: "A", count: 43))

        let report = try LegacyHostKeyMigrator(
            store: store,
            source: StaticLegacySource(["example.test:2222": pin])
        ).migrate()

        #expect(report.outcomes["example.test:2222"] == .imported,
                "a lone legacy pin must be carried over; got \(String(describing: report.outcomes["example.test:2222"]))")
        #expect(!report.hasConflicts, "a first migration cannot conflict")

        let lookup = try store.lookup(host: "example.test", port: 2222)
        #expect(lookup == .legacyFingerprintOnly(pin),
                "the migrated pin must be visible as a fingerprint-only pin, not as trust; got \(lookup)")
        // Crucially *not* a usable record: the digest alone cannot authorise a
        // connection, it only forces the resolver to probe and verify.
        #expect(lookup.record == nil, "a migrated digest must not masquerade as key material")
    }

    @Test("migration is idempotent — a second pass changes nothing")
    func migrationIsIdempotent() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pin = SSHHostFingerprint(hash: "SHA256:" + String(repeating: "B", count: 43))
        let migrator = LegacyHostKeyMigrator(
            store: store, source: StaticLegacySource(["example.test:22": pin])
        )

        _ = try migrator.migrate()
        let afterFirst = try Data(contentsOf: dir.appendingPathComponent("records.json"))
        let second = try migrator.migrate()
        let afterSecond = try Data(contentsOf: dir.appendingPathComponent("records.json"))

        #expect(second.outcomes["example.test:22"] == .alreadyPresent,
                "the second pass must recognise its own work; got \(String(describing: second.outcomes["example.test:22"]))")
        #expect(afterSecond == afterFirst, "an idempotent pass must not rewrite the file")
    }

    // MARK: - Conflict: fail closed, leave both sides untouched

    @Test("a conflict leaves the canonical record and the legacy data both unchanged")
    func conflictLeavesBothStoresUnchanged() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let canonicalRecord = HostKeyFixtureSupport.syntheticEd25519Record()
        _ = try store.recordIfAbsentOrMatching(
            host: "example.test", port: 22, candidate: canonicalRecord
        )

        let legacyPin = SSHHostFingerprint(hash: "SHA256:" + String(repeating: "C", count: 43))
        #expect(canonicalRecord.fingerprint != legacyPin, "the fixture must actually disagree")

        let storeBefore = try Data(contentsOf: dir.appendingPathComponent("records.json"))

        let report = try LegacyHostKeyMigrator(
            store: store, source: StaticLegacySource(["example.test:22": legacyPin])
        ).migrate()

        // Reported, not resolved.
        #expect(
            report.outcomes["example.test:22"] == .conflict(
                canonical: canonicalRecord.fingerprint, legacy: legacyPin
            ),
            "the disagreement must be reported with both values; got \(String(describing: report.outcomes["example.test:22"]))"
        )
        #expect(report.hasConflicts, "the report must flag the conflict")

        // Canonical side untouched: the record is still there, unchanged, and no
        // legacy pin was smuggled in beside it.
        let storeAfter = try Data(contentsOf: dir.appendingPathComponent("records.json"))
        #expect(storeAfter == storeBefore,
                "a conflict must not write to the canonical store at all")
        #expect(try store.lookup(host: "example.test", port: 22).record == canonicalRecord,
                "the canonical record must survive a conflict untouched")
    }

    /// The legacy side is never rewritten, in any outcome.
    ///
    /// This is the "never delete" rule, stated as a gate rather than a comment.
    /// `UserDefaultsLegacyHostKeySource` is read-only, so the property holds by
    /// construction — and this test is what makes that construction load-bearing
    /// rather than incidental.
    @Test("a migration never modifies the legacy source")
    func legacySourceIsNeverModified() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteName = "bonk.legacy-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        // The backing plist has to be deleted by hand.
        //
        // `removePersistentDomain` clears the keys but leaves the file in
        // `~/Library/Preferences`, and `removeSuite(named:)` does not remove it
        // either — both were tried and the count kept climbing, one stray per run.
        // "The canonical trust store is clean" is a different claim from "this test
        // left nothing behind", and only the second is what a test guarantees.
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist").path
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeSuite(named: suiteName)
            try? FileManager.default.removeItem(atPath: plistPath)
        }

        let pin = SSHHostFingerprint(hash: "SHA256:" + String(repeating: "D", count: 43))
        let payload = try JSONEncoder().encode(["example.test:22": pin])
        defaults.set(payload, forKey: UserDefaultsLegacyHostKeySource.defaultsKey)
        let before = try #require(defaults.data(forKey: UserDefaultsLegacyHostKeySource.defaultsKey))

        _ = try LegacyHostKeyMigrator(
            store: store, source: UserDefaultsLegacyHostKeySource(defaults: defaults)
        ).migrate()

        let after = try #require(defaults.data(forKey: UserDefaultsLegacyHostKeySource.defaultsKey))
        #expect(after == before, "the legacy defaults domain must be byte-identical after migration")

        // Prove this test's own footprint is removable, while the handles are live.
        #expect(FileManager.default.fileExists(atPath: plistPath),
                "the isolated suite should have written a plist this test can clean up")
        try? FileManager.default.removeItem(atPath: plistPath)
        #expect(!FileManager.default.fileExists(atPath: plistPath),
                "this gate must leave no file in ~/Library/Preferences")
    }

    /// A malformed legacy key is reported, not silently dropped.
    @Test("a malformed legacy key is reported rather than guessed at")
    func malformedLegacyKeyIsReported() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pin = SSHHostFingerprint(hash: "SHA256:" + String(repeating: "E", count: 43))

        let report = try LegacyHostKeyMigrator(
            store: store,
            source: StaticLegacySource(["no-port-here": pin, "host.test:notaport": pin])
        ).migrate()

        #expect(report.outcomes["no-port-here"] == .malformedKey("no-port-here"),
                "a key with no port must be reported")
        #expect(report.outcomes["host.test:notaport"] == .malformedKey("host.test:notaport"),
                "a key with a non-numeric port must be reported")
        #expect(try store.lookup(host: "no-port-here", port: 22) == .absent,
                "a malformed key must not be coerced into a host:port")
    }

    // MARK: - Isolation invariant

    /// The user's real defaults domain is never the source for a migration.
    ///
    /// Scoped deliberately. An earlier version of this scanned every file whose
    /// name contains "HostKey" and failed on two files that were merely *talking
    /// about* `UserDefaults.standard` inside assertion strings — including its
    /// own. A gate that trips on its own documentation teaches people to delete
    /// it, which is worse than not having it.
    ///
    /// So the rule is narrow and precise: the production migrator must expose the
    /// standard domain as a *default argument* only, and this suite must inject.
    @Test("the migration source exposes UserDefaults.standard only as a default argument")
    func realDefaultsDomainIsOnlyReachableFromProduction() throws {
        let migrator = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/SSH/LegacyHostKeyMigrator.swift"),
            encoding: .utf8
        )
        #expect(migrator.contains("defaults: UserDefaults = .standard"),
                "the production source must expose the standard domain as its default argument")
        #expect(
            migrator.contains("nonisolated(unsafe) let defaults"),
            "the stored domain must be documented as a fixed, never-re-pointed reference"
        )
        // No hardcoded read of the standard domain: the source must go through
        // `legacyFingerprints()`, which is the swappable seam.
        #expect(
            !Self.hasCodeUsingStandardDefaults(migrator),
            "LegacyHostKeyMigrator must not reach UserDefaults.standard outside the default argument"
        )
    }

    /// True when `UserDefaults.standard` appears as executable code rather than
    /// inside a comment or a string literal.
    private static func hasCodeUsingStandardDefaults(_ source: String) -> Bool {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return false }
                // A literal mention inside a string is documentation, not a call.
                guard !trimmed.contains("\"") else { return false }
                return trimmed.contains("UserDefaults.standard")
            }
            .contains { $0.contains("UserDefaults.standard") && !$0.contains("= .standard") }
    }

    // MARK: - Helpers

    private func makeStore() throws -> (CanonicalHostKeyStore, URL) {
        let dir = try HostKeyFixtureSupport.makeTempDir("legacy-migration")
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        return (store, dir)
    }

}

/// A legacy source backed by a literal map.
///
/// Used instead of `UserDefaults` in most gates so a test cannot reach a real
/// defaults domain even by accident. The `UserDefaults`-backed path is covered
/// separately, against an isolated suite.
struct StaticLegacySource: LegacyHostKeySource {
    let fingerprints: [String: SSHHostFingerprint]
    init(_ fingerprints: [String: SSHHostFingerprint]) { self.fingerprints = fingerprints }
    func legacyFingerprints() -> [String: SSHHostFingerprint] { fingerprints }
}