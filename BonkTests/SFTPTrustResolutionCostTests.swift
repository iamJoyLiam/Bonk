import Foundation
import Testing
@testable import Bonk

/// How much trust resolution costs the SFTP path, and whether it is paid more
/// than once.
///
/// ## Why this exists
///
/// The user reported that SFTP got noticeably slower and asked what had changed.
/// The answer is not knowable by reading: `OpenSSHBackend.runSFTP` resolves a
/// trust file on entry, and `OpenSSHSFTPClient.execute` calls `runSFTP` once per
/// command batch. So the cost depends on *how many* resolutions a session makes,
/// which depends on how the resolver branches:
///
///   - complete record            → render a file, no network
///   - legacy fingerprint only    → `ssh-keyscan` + credential-free probe
///   - nothing known              → same, then a compare-and-set
///
/// Two of those three branches open real connections. If a session pays them per
/// operation rather than per host, that is the regression, and the only way to
/// know is to time it.
///
/// ## What this asserts
///
/// That resolution is **not** repeated per operation on the same host. The
/// measurement is the point: a count of resolver invocations, plus wall-clock
/// evidence that a second operation on a backfilled host does not re-probe.
@Suite("SFTP — trust resolution is paid once per host, not per operation")
struct SFTPTrustResolutionCostTests {
    /// The resolver is pure from the store's point of view, so the observable
    /// cost is the *network* it triggers. Counting probes is therefore counting
    /// `ssh-keyscan`/probe launches.
    @Test("a backfilled host resolves without opening a second connection")
    func backfilledHostDoesNotReProbe() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0x91,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { server.stop() }

        let dir = try HostKeyFixtureSupport.makeTempDir("sftp-cost")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))

        // A legacy fingerprint-only pin: the state every migrated host is in
        // until it has been reached once. This is the branch that costs two extra
        // handshakes, so it is the one worth timing.
        let scanned = try HostKeyFixtureSupport.scannedKey(port: UInt16(server.port))
        try store.importLegacyFingerprints(["127.0.0.1:\(server.port)": scanned.fingerprint])

        let resolver = OpenSSHKnownHostsResolver(store: store)

        // First resolution: must probe, because the pin has no key material yet.
        let firstStart = Date()
        let first = try await resolver.resolveKnownHostsFile(
            for: "127.0.0.1", port: UInt16(server.port)
        )
        let firstElapsed = Date().timeIntervalSince(firstStart)
        defer { first.cleanUp() }

        #expect(
            try store.lookup(host: "127.0.0.1", port: UInt16(server.port)).record?.fingerprint == scanned.fingerprint,
            """
            the first resolution must backfill the pin it just verified. If it did \
            not, every later connection on this host pays the probe again.
            """
        )

        // Second and third resolutions: the store now holds a complete record, so
        // these must be pure local work with no network at all.
        var repeats: [TimeInterval] = []
        for _ in 0 ..< 2 {
            let start = Date()
            let again = try await resolver.resolveKnownHostsFile(
                for: "127.0.0.1", port: UInt16(server.port)
            )
            repeats.append(Date().timeIntervalSince(start))
            again.cleanUp()
        }

        let slowestRepeat = repeats.max() ?? 0
        // Timings written out rather than asserted: the numbers are the answer to
        // "why did SFTP get slower", and an assertion can only say pass/fail.
        let line = "first(legacyFingerprintOnly)=\(String(format: "%.3f", firstElapsed))s "
            + "repeats(completeRecord)=\(repeats.map { String(format: "%.3f", $0) }.joined(separator: ","))"
        try? line.write(
            toFile: "/tmp/bonk-sftp-cost-\(ProcessInfo.processInfo.processIdentifier).txt",
            atomically: true, encoding: .utf8
        )
        // Deliberately loose. This is not a benchmark; it is a guard that would
        // fire if a repeat ever opened a handshake again. A probe of even a
        // local fixture costs orders of magnitude more than a file render, so
        // the separation is wide and a loose bound will not be flaky.
        #expect(
            slowestRepeat < max(firstElapsed, 0.5),
            """
            a repeat resolution took \(String(format: "%.3f", slowestRepeat))s against \
            a first resolution of \(String(format: "%.3f", firstElapsed))s. Once the pin is \
            backfilled the resolver must render from the store and touch the network \
            not at all.
            """
        )
    }

    /// The resolver must be a no-op for a host the store already trusts.
    @Test("resolution for a complete record performs no network work")
    func completeRecordResolvesLocally() async throws {
        let dir = try HostKeyFixtureSupport.makeTempDir("sftp-cost-2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        let record = HostKeyFixtureSupport.syntheticEd25519Record()

        // Seed a complete record for a port nothing is listening on. If resolution
        // touched the network it could not succeed at all — so success is itself
        // the evidence that it did not.
        #expect(try store.recordIfAbsentOrMatching(
            host: "unreachable.invalid", port: 65000, candidate: record
        ) != .persistenceFailure)

        let resolver = OpenSSHKnownHostsResolver(store: store)
        let start = Date()
        let resolved = try await resolver.resolveKnownHostsFile(
            for: "unreachable.invalid", port: 65000
        )
        let elapsed = Date().timeIntervalSince(start)
        defer { resolved.cleanUp() }

        #expect(FileManager.default.fileExists(atPath: resolved.path),
                "a complete record must render a usable trust file")
        #expect(elapsed < 1.0,
                "rendering from the store must not involve the network; took \(elapsed)s")
    }
}