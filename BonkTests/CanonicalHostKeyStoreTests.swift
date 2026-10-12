import Crypto
import Darwin
import Foundation
import Testing
@testable import Bonk

/// Step 3 gate: the canonical host-key record and its compare-and-set store.
///
/// Scoped to storage and the record contract only. No connection path is wired
/// up yet, so AUDIT-FIND-001 is untouched — `accept-new` is still in force and
/// the transports still disagree. What is established here is that the store
/// cannot silently replace one trusted key with another, cannot report a write
/// as durable before it is, and fails closed on records that disagree with
/// themselves.
///
/// Isolation: every test uses a fresh temp directory. Nothing reads or writes
/// the user's app-private trust state.
@Suite("Canonical host-key store — compare-and-set")
struct CanonicalHostKeyStoreTests {
    private func makeStore() throws -> (CanonicalHostKeyStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        return (store, dir)
    }

    /// Build a record whose fingerprint and keyType are derived from the blob, so
    /// the record is internally consistent by construction — as a real handshake
    /// would produce.
    ///
    /// The blob is a genuine SSH wire-format ed25519 public key
    /// (`<len>"ssh-ed25519"<len><32 bytes>`). An earlier draft used arbitrary
    /// bytes, which no valid key could be built from — 13 of 15 tests then failed
    /// at fixture construction rather than at the behaviour under test.
    private func makeRecord(
        seed: UInt8,
        capability: HostKeyCapability = .nativeAndOpenSSH
    ) throws -> HostKeyRecord {
        var key = Data(repeating: 0, count: 32)
        for index in key.indices { key[index] = UInt8(index &+ Int(seed)) }
        var blob = Data()
        let type = Array("ssh-ed25519".utf8)
        blob.append(UInt8((type.count >> 24) & 0xFF))
        blob.append(UInt8((type.count >> 16) & 0xFF))
        blob.append(UInt8((type.count >> 8) & 0xFF))
        blob.append(UInt8(type.count & 0xFF))
        blob.append(contentsOf: type)
        blob.append(contentsOf: [0, 0, 0, 32])
        blob.append(key)

        let parsed = try #require(HostKeyBlob.parse(blob), "test blob must be a valid SSH host key")
        #expect(parsed.keyType == "ssh-ed25519", "fixture must parse as ed25519")
        return HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: capability
        )
    }

    // MARK: - Record contract

    @Test("a record's fields are re-derivable from its own key material")
    func recordFieldsAreSelfConsistent() throws {
        let record = try makeRecord(seed: 0x11)

        #expect(HostKeyBlob.validate(record) == nil, "a consistent record must validate")
        // Fingerprint must be the digest of the blob itself, not a stored string.
        #expect(record.fingerprint == HostKeyBlob.fingerprint(of: record.keyBlob))
        // Two seeds must give different keys, or "a different key conflicts"
        // would be vacuously satisfied by an identical candidate.
        let other = try makeRecord(seed: 0x12)
        #expect(other.fingerprint != record.fingerprint, "distinct seeds must yield distinct keys")
    }

    @Test("a record whose fields disagree with its key material fails closed")
    func recordWithInconsistentFieldsIsRejected() throws {
        let record = try makeRecord(seed: 0x22)

        // Fingerprint that does not match the blob.
        let wrongFingerprint = HostKeyRecord(
            fingerprint: SSHHostFingerprint(hash: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            keyType: record.keyType,
            keyBlob: record.keyBlob,
            capability: record.capability
        )
        #expect(HostKeyBlob.validate(wrongFingerprint) != nil,
                "a fingerprint that does not match the blob must not validate")

        // Key type that does not match the blob.
        let wrongType = HostKeyRecord(
            fingerprint: record.fingerprint,
            keyType: "ssh-rsa",
            keyBlob: record.keyBlob,
            capability: record.capability
        )
        #expect(HostKeyBlob.validate(wrongType) != nil,
                "a keyType that contradicts the blob must not validate")

        // Structurally broken blob.
        let brokenBlob = HostKeyRecord(
            fingerprint: record.fingerprint,
            keyType: record.keyType,
            keyBlob: Data([0xFF, 0xFF, 0xFF, 0xFF]),
            capability: record.capability
        )
        #expect(HostKeyBlob.validate(brokenBlob) != nil,
                "an unparseable blob must not validate")
    }

    @Test("RSA wire format maps to its signature algorithms, not to itself")
    func rsaWireFormatMapsToSignatureAlgorithms() {
        // `ssh-rsa` is a wire format. Per RFC 8332 the same key may be used with
        // rsa-sha2-256/512, and OpenSSH knows those only as signature algorithms.
        let algorithms = HostKeyBlob.signatureAlgorithms(forKeyType: "ssh-rsa")
        #expect(algorithms.first == "rsa-sha2-512",
                "the modern RSA signature must be preferred; got \(algorithms)")
        #expect(algorithms.contains("rsa-sha2-256"))
        #expect(algorithms.contains("ssh-rsa"),
                "SHA-1 remains listed, last, for servers offering nothing else")
        #expect(algorithms.last == "ssh-rsa", "SHA-1 must be the final fallback")

        // Non-RSA formats map to themselves.
        #expect(HostKeyBlob.signatureAlgorithms(forKeyType: "ssh-ed25519") == ["ssh-ed25519"])
        #expect(HostKeyBlob.signatureAlgorithms(forKeyType: "ecdsa-sha2-nistp384") == ["ecdsa-sha2-nistp384"])
    }

    // MARK: - Lookup states

    @Test("lookup distinguishes absent, legacy-only, complete and corrupt")
    func lookupDistinguishesFourStates() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "example.test"
        let port: UInt16 = 2222

        // absent
        #expect(try store.lookup(host: host, port: port) == .absent)

        // legacy fingerprint only
        let legacy = try makeRecord(seed: 0x31).fingerprint
        try store.importLegacyFingerprints(["\(host):\(port)": legacy])
        guard case .legacyFingerprintOnly(let seen) = try store.lookup(host: host, port: port) else {
            Issue.record("a fingerprint-only pin must read as legacyFingerprintOnly, not absent")
            return
        }
        #expect(seen == legacy)
        // The distinction that matters: this is NOT absent, so a migration
        // handshake cannot treat it as first contact.
        #expect(try store.lookup(host: host, port: port).hasEstablishedTrust)

        // complete
        let recordA = try makeRecord(seed: 0x31)
        _ = try store.recordIfAbsentOrMatching(host: host, port: port, candidate: recordA)
        guard case .complete(let complete) = try store.lookup(host: host, port: port) else {
            Issue.record("a written record must read as complete")
            return
        }
        #expect(complete == recordA)

        // A different host is still absent — state must not leak across hosts.
        #expect(try store.lookup(host: "other.test", port: port) == .absent)
        #expect(try store.lookup(host: host, port: port + 1) == .absent)
    }

    @Test("a corrupt on-disk record reads as invalidOrCorrupt, never as absent")
    func corruptRecordIsNotAbsence() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "corrupt.test"
        let port: UInt16 = 22

        // Write a record whose stored fingerprint contradicts its blob.
        let record = try makeRecord(seed: 0x44)
        let tampered = HostKeyRecord(
            fingerprint: SSHHostFingerprint(hash: "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"),
            keyType: record.keyType,
            keyBlob: record.keyBlob,
            capability: record.capability
        )
        // Bypass the store's own write path to plant an inconsistent file.
        let payload = try JSONEncoder().encode(
            CanonicalHostKeyFile(records: ["\(host):\(port)": tampered], legacyFingerprints: [:])
        )
        try payload.write(to: store.fileURL)

        guard case .invalidOrCorrupt = try store.lookup(host: host, port: port) else {
            Issue.record("an inconsistent record must read as invalidOrCorrupt, never as absent")
            return
        }
        // Most importantly: not absence, because absence re-authorises trust.
        #expect(try !store.lookup(host: host, port: port).hasEstablishedTrust)
    }

    // MARK: - Compare-and-set

    @Test("CAS: absent inserts, matching is idempotent, a different key conflicts")
    func compareAndSetOutcomes() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "cas.test"
        let port: UInt16 = 22
        let recordA = try makeRecord(seed: 0x51)
        let recordB = try makeRecord(seed: 0x52)

        #expect(try store.recordIfAbsentOrMatching(host: host, port: port, candidate: recordA) == .inserted)
        #expect(try store.recordIfAbsentOrMatching(host: host, port: port, candidate: recordA) == .alreadyMatching)

        let outcome = try store.recordIfAbsentOrMatching(host: host, port: port, candidate: recordB)
        #expect(outcome == .conflict, "a different key must conflict, got \(outcome)")

        // A must survive untouched — the whole point of the conflict.
        #expect(try store.lookup(host: host, port: port).record == recordA,
                "a conflicting write must not replace the trusted key")
    }

    @Test("CAS never overwrites, and a conflicting candidate cannot be retried around")
    func conflictDoesNotOverwriteAndIsNotBypassable() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "overwrite.test"
        let port: UInt16 = 22
        let trusted = try makeRecord(seed: 0x61)
        let attacker = try makeRecord(seed: 0x62)

        _ = try store.recordIfAbsentOrMatching(host: host, port: port, candidate: trusted)
        #expect(try store.recordIfAbsentOrMatching(host: host, port: port, candidate: attacker) == .conflict)

        // Repeating must not change anything: a conflict is terminal, not a
        // transient the caller can grind past.
        for _ in 0 ..< 5 {
            _ = try store.recordIfAbsentOrMatching(host: host, port: port, candidate: attacker)
        }
        #expect(try store.lookup(host: host, port: port).record == trusted,
                "repeated conflicting writes must never displace trusted key material")
    }

    @Test("a candidate that disagrees with itself is refused rather than stored")
    func selfInconsistentCandidateIsRefused() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "selfinconsistent.test"
        let port: UInt16 = 22
        let record = try makeRecord(seed: 0x71)
        let broken = HostKeyRecord(
            fingerprint: SSHHostFingerprint(hash: "SHA256:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"),
            keyType: record.keyType,
            keyBlob: record.keyBlob,
            capability: record.capability
        )
        #expect(try store.recordIfAbsentOrMatching(host: host, port: port, candidate: broken) == .conflict)
        #expect(try store.lookup(host: host, port: port) == .absent,
                "a self-inconsistent candidate must not create a record")
    }

    // MARK: - Backfill

    @Test("backfill completes a fingerprint-only pin when the key matches")
    func backfillCompletesMatchingLegacyPin() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "legacy-match.test"
        let port: UInt16 = 2222
        let record = try makeRecord(seed: 0x81)
        try store.importLegacyFingerprints(["\(host):\(port)": record.fingerprint])

        let outcome = try store.backfillKeyMaterial(
            host: host, port: port,
            expectedLegacyFingerprint: record.fingerprint,
            candidate: record
        )
        #expect(outcome == .backfilled, "got \(outcome)")
        #expect(try store.lookup(host: host, port: port).record == record)

        // Re-running is idempotent.
        #expect(
            try store.backfillKeyMaterial(
                host: host, port: port,
                expectedLegacyFingerprint: record.fingerprint,
                candidate: record
            ) == .alreadyComplete
        )
    }

    @Test("backfill refuses a candidate that contradicts the legacy pin")
    func backfillRefusesMismatchedCandidate() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "legacy-mismatch.test"
        let port: UInt16 = 2222
        let pinned = try makeRecord(seed: 0x91)
        let other = try makeRecord(seed: 0x92)
        try store.importLegacyFingerprints(["\(host):\(port)": pinned.fingerprint])

        let outcome = try store.backfillKeyMaterial(
            host: host, port: port,
            expectedLegacyFingerprint: pinned.fingerprint,
            candidate: other
        )
        #expect(outcome == .conflict, "got \(outcome)")

        // The pin must remain, still fingerprint-only, unbackfilled.
        guard case .legacyFingerprintOnly(let still) = try store.lookup(host: host, port: port) else {
            Issue.record("a refused backfill must leave the legacy pin intact")
            return
        }
        #expect(still == pinned.fingerprint)
    }

    @Test("backfill refuses when the pin changed since it was read")
    func backfillIsConditionalOnThePin() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "legacy-stale.test"
        let port: UInt16 = 2222
        let pinned = try makeRecord(seed: 0xA1)
        try store.importLegacyFingerprints(["\(host):\(port)": pinned.fingerprint])

        // A caller holding a stale expectation must not be able to backfill.
        let staleExpectation = SSHHostFingerprint(
            hash: "SHA256:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
        )
        #expect(
            try store.backfillKeyMaterial(
                host: host, port: port,
                expectedLegacyFingerprint: staleExpectation,
                candidate: pinned
            ) == .conflict,
            "backfill must verify the pin still matches what the caller read"
        )
        // And a backfill with no pin at all must conflict.
        #expect(
            try store.backfillKeyMaterial(
                host: "never-pinned.test", port: port,
                expectedLegacyFingerprint: pinned.fingerprint,
                candidate: pinned
            ) == .conflict,
            "backfill must not establish trust where none existed"
        )
    }

    // MARK: - Concurrency

    @Test("concurrent first contacts: at most one wins, the rest conflict")
    func concurrentFirstContactsElectOneWinner() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "concurrent.test"
        let port: UInt16 = 22

        // Two *different* keys racing to establish trust, and several instances
        // of the store addressing the same file — the race a per-instance lock
        // would not prevent.
        let recordA = try makeRecord(seed: 0xB1)
        let recordB = try makeRecord(seed: 0xB2)

        let instances: [CanonicalHostKeyStore] = try (0 ..< 6).map { _ in
            try CanonicalHostKeyStore(fileURL: store.fileURL)
        }
        let outcomes = await withTaskGroup(of: (Int, HostKeyCASOutcome, HostKeyRecord).self) { group in
            for (index, instance) in instances.enumerated() {
                let candidate = index % 2 == 0 ? recordA : recordB
                group.addTask {
                    let outcome = try? instance.recordIfAbsentOrMatching(
                        host: host, port: port, candidate: candidate
                    )
                    return (index, outcome ?? .persistenceFailure, candidate)
                }
            }
            var collected: [(Int, HostKeyCASOutcome, HostKeyRecord)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        let inserted = outcomes.filter { $0.1 == .inserted }
        let matching = outcomes.filter { $0.1 == .alreadyMatching }
        #expect(inserted.count <= 1,
                "at most one writer may establish trust; \(inserted.count) reported inserted")

        // Everyone else's outcome must be a terminal one, never a silent success
        // on a different key.
        for (_, outcome, candidate) in outcomes {
            if outcome != .inserted {
                #expect(outcome == .alreadyMatching || outcome == .conflict || outcome == .persistenceFailure,
                        "unexpected outcome \(outcome)")
            }
            if outcome == .alreadyMatching {
                #expect(try store.lookup(host: host, port: port).record == candidate,
                        "alreadyMatching must only be reported for the key actually stored")
            }
        }

        // Whatever happened, the file holds exactly one key.
        let stored = try store.lookup(host: host, port: port)
        #expect(stored.record == recordA || stored.record == recordB,
                "exactly one of the racing keys must be trusted")

        // The invariant that matters: `alreadyMatching` is only ever true for the
        // key that actually ended up stored. Whichever of A or B won the race,
        // reports of "already matching" must name that winner and never the
        // loser.
        //
        // An earlier version of this assertion was `if stored != recordA then
        // matching.isEmpty`, which is wrong: when B wins, B's racers legitimately
        // report alreadyMatching. The correct statement is per-outcome, and it
        // catches a store that returns alreadyMatching for a key it did not keep.
        let winner = try #require(stored.record, "a winner must be stored")
        for (_, outcome, candidate) in outcomes where outcome == .alreadyMatching {
            #expect(candidate == winner,
                    "alreadyMatching was reported for a key the store does not hold")
        }
        for (_, outcome, candidate) in outcomes where outcome == .conflict {
            #expect(candidate != winner,
                    "conflict was reported for the key the store already holds")
        }
    }

    // MARK: - Durability

    @Test("a committed record survives reopening the file")
    func committedRecordSurvivesReload() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = "reload.test"
        let port: UInt16 = 2222
        let record = try makeRecord(seed: 0xC1)

        #expect(try store.recordIfAbsentOrMatching(host: host, port: port, candidate: record) == .inserted)

        // A completely separate instance, as a relaunch would use.
        let reopened = try CanonicalHostKeyStore(fileURL: store.fileURL)
        #expect(try reopened.lookup(host: host, port: port).record == record,
                "a committed record must be readable by a fresh store instance")

        // And the bytes on disk are valid JSON, not a half-written file.
        let data = try Data(contentsOf: store.fileURL)
        #expect(!data.isEmpty, "the committed file must not be empty")
        #expect((try? JSONDecoder().decode(CanonicalHostKeyFile.self, from: data)) != nil,
                "the committed file must be complete and parseable")

        // No temporary files left behind.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "temporary files must be renamed away; found \(leftovers)")
    }

    @Test("a commit that cannot be durable reports persistenceFailure, never success")
    func undurableCommitReportsFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-nodir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        // Constructed while the directory is still writable, so the lock is
        // acquirable. The directory is then made read-only, which is what makes
        // the commit undurable: no temp file can be created, so the rename can
        // never happen. Reads still work, so the pin below is readable.
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))

        let record = try makeRecord(seed: 0xD1)
        try store.importLegacyFingerprints(["nodir.test:22": record.fingerprint])
        _ = chmod(dir.path, mode_t(0o500))
        defer { _ = chmod(dir.path, mode_t(0o700)) }

        let outcome = try store.recordIfAbsentOrMatching(
            host: "other.test", port: 22, candidate: record
        )
        #expect(outcome == .persistenceFailure,
                "an undurable commit must report persistenceFailure, got \(outcome)")

        // With the candidate matching the pin, this reaches the commit and so
        // exercises the durability boundary rather than a conflict.
        #expect(
            try store.backfillKeyMaterial(
                host: "nodir.test", port: 22,
                expectedLegacyFingerprint: record.fingerprint,
                candidate: record
            ) == .persistenceFailure,
            "an undurable backfill must report persistenceFailure"
        )
        // Backfill with no pin must still conflict rather than invent trust.
        #expect(
            try store.backfillKeyMaterial(
                host: "unpinned.test", port: 22,
                expectedLegacyFingerprint: record.fingerprint,
                candidate: record
            ) == .conflict,
            "backfill with no legacy pin must conflict, not invent trust"
        )

        // A store that cannot take its lock must not be usable. Separate from the
        // durability case above: this fails at construction, which is the shape
        // of an unwritable Application Support directory on first launch.
        let unwritableDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-unlockable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unwritableDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            _ = chmod(unwritableDir.path, mode_t(0o700))
            try? FileManager.default.removeItem(at: unwritableDir)
        }
        _ = chmod(unwritableDir.path, mode_t(0o500))
        #expect(throws: CanonicalHostKeyStoreError.self) {
            _ = try CanonicalHostKeyStore(
                fileURL: unwritableDir.appendingPathComponent("records.json")
            )
        }

        // The pin must survive the failed attempts rather than being consumed.
        guard case .legacyFingerprintOnly = try store.lookup(host: "nodir.test", port: 22) else {
            Issue.record("a failed commit must leave the legacy pin intact")
            return
        }
        // And no record was created for the host whose commit failed.
        #expect(try store.lookup(host: "other.test", port: 22) == .absent)
    }

    @Test("an unparseable store file is an error, not an empty store")
    func unparseableFileIsNotEmptiness() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(throws: CanonicalHostKeyStoreError.self) {
            _ = try store.lookup(host: "x.test", port: 22)
        }
    }
}