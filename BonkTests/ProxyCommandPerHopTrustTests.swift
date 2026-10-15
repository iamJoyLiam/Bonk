import Foundation
import Testing
import Citadel
@testable import Bonk

/// AUDIT-FIND-001, per-hop trust isolation for `ProxyCommand` / jump hosts.
///
/// ## Why this gate exists
///
/// A jump-host connection is two SSH connections wearing one command line. The
/// outer `ssh` verifies the **target**'s host key; the inner `ssh` inside
/// `ProxyCommand` verifies the **jump host's**. If both are pointed at one trust
/// file, then either host's key is checked against the other's pin, and the
/// connection fails for reasons that look like an ordinary key problem — or, if
/// the shared file is empty or newly written, succeeds for the wrong reason.
///
/// That is the easiest place in this codebase to reintroduce AUDIT-FIND-001,
/// because the reuse looks like a harmless optimisation: resolve once, pass the
/// path along. It was already present once — every call site passed the
/// *target's* `explicitOverride` into the jump resolution, three lines below a
/// comment asserting that each hop gets its own record. The comment was right
/// and the code was wrong.
///
/// ## What is asserted
///
/// Three layers, because each catches a different regression:
///
///  1. **argv** — the outer connection's `UserKnownHostsFile` and the path inside
///     the `ProxyCommand` string must differ. This is the artifact production
///     actually hands to `/usr/bin/ssh`.
///  2. **file contents** — each of those two files must exist and must carry its
///     *own* host's key. Two different paths pointing at the same pin is still
///     one trust decision, and "paths differ" alone would not catch it.
///  3. **store integrity** — after the connection, the canonical store still holds
///     exactly the two pinned keys, and nothing was written for any other host.
///     A hop that resolved by first-contact probe rather than by pin would show
///     up here as a new record.
///
/// Layers 1 and 2 exist because of a defect this audit already produced once: a
/// resolver that handed `ssh` a path to a file it had just deleted still produced
/// the correct-looking refusal, because a missing trust file and a substituted
/// key are reported identically. Asserting that two paths differ would have gone
/// green while both files were absent.
@Suite("AUDIT-FIND-001 — each hop resolves its own trust record")
struct ProxyCommandPerHopTrustTests {
    // MARK: - Layer 1 + 2: the argv, and what is actually in each file

    @Test("the jump hop and the target are pointed at different trust files, each carrying its own key")
    func proxyCommandCarriesItsOwnTrustFile() async throws {
        let ports = try ProxyHopFixturePorts.claimPair()

        let jumpServer = try await BenchSSHServer.start(
            hostKeySeed: 0x11,
            password: BenchSSHServerSmokeTests.password,
            port: ports.jump,
            sftpDelegate: BenchSFTPDelegate()
        )
        let targetServer = try await BenchSSHServer.start(
            hostKeySeed: 0x22,
            password: BenchSSHServerSmokeTests.password,
            port: ports.target,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { jumpServer.stop(); targetServer.stop() }

        let dir = try HostKeyFixtureSupport.makeTempDir("perhop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))

        let jumpKey = try HostKeyFixtureSupport.scannedKey(port: UInt16(ports.jump))
        let targetKey = try HostKeyFixtureSupport.scannedKey(port: UInt16(ports.target))
        #expect(jumpKey.fingerprint != targetKey.fingerprint,
                "the two fixture servers must present different keys, or the test proves nothing")

        #expect(try store.recordIfAbsentOrMatching(
            host: "127.0.0.1", port: UInt16(ports.jump), candidate: jumpKey
        ) != .persistenceFailure, "could not pin the jump host")
        #expect(try store.recordIfAbsentOrMatching(
            host: "127.0.0.1", port: UInt16(ports.target), candidate: targetKey
        ) != .persistenceFailure, "could not pin the target host")

        let recorder = RecordingOpenSSHProcessSpawner(recordOnly: true)
        let backend = try OpenSSHBackend(
            config: SSHConnectionConfig(
                host: "127.0.0.1",
                port: UInt16(ports.target),
                username: "bench",
                authMethod: .password(BenchSSHServerSmokeTests.password),
                jumpHost: SSHJumpHostConfig(
                    host: "127.0.0.1",
                    port: UInt16(ports.jump),
                    username: "bench",
                    authMethod: .password(BenchSSHServerSmokeTests.password)
                ),
                maxReconnectAttempts: 0,
                bypassControlMaster: true
            ),
            spawner: recorder,
            knownHostsResolver: OpenSSHKnownHostsResolver(store: store)
        )
        defer { backend.close() }
        _ = try? await backend.openPTY(cols: 80, rows: 24, termType: "xterm-256color", onExit: {})

        let invocation = try #require(
            recorder.connectionInvocation(port: ports.target),
            "no outer /usr/bin/ssh launch recorded; captured: \(recorder.recorded.map { $0.executable })"
        )
        let argv = invocation.arguments

        // --- Layer 1: two distinct trust files. ---
        let targetPath = try #require(
            OpenSSHTrustFileAssertions.knownHostsPath(in: argv),
            "the outer connection names no UserKnownHostsFile; argv: \(argv)"
        )
        let proxyCommand = try #require(
            argv.first { $0.hasPrefix("ProxyCommand=") },
            "a jump-host connection must carry a ProxyCommand; argv: \(argv)"
        )
        let jumpPath = try #require(
            OpenSSHTrustFileAssertions.knownHostsPath(in: [proxyCommand]),
            """
            the ProxyCommand names no UserKnownHostsFile. The inner ssh verifies \
            the JUMP host's key; without its own trust file it inherits whatever \
            default ssh would use. ProxyCommand: \(proxyCommand)
            """
        )

        #expect(
            targetPath != jumpPath,
            """
            both hops were pointed at the same trust file (\(targetPath)). The \
            target's key would then be checked against the jump host's pin and the \
            jump host's key against the target's. This is AUDIT-FIND-001's bypass \
            reintroduced through the jump-host path.
            """
        )

        // --- Layer 2: each file exists and carries its own host's key. ---
        try OpenSSHTrustFileAssertions.expectTrustFile(targetPath, carries: targetKey, labelled: "target")
        try OpenSSHTrustFileAssertions.expectTrustFile(jumpPath, carries: jumpKey, labelled: "jump")

        // --- Layer 3: nothing extra was written. ---
        #expect(try store.lookup(host: "127.0.0.1", port: UInt16(ports.jump)).record?.fingerprint == jumpKey.fingerprint,
                "the jump host's pin changed during the connection")
        #expect(try store.lookup(host: "127.0.0.1", port: UInt16(ports.target)).record?.fingerprint == targetKey.fingerprint,
                "the target's pin changed during the connection")
    }

    // MARK: - Helpers

}

// MARK: - Two-port fixture

/// Two ports for the two hops, claimed from the shared fixture allocator.
///
/// A pair rather than a single port because per-hop isolation is meaningless with
/// one host: there is nothing to isolate from. Two separate claims from separate
/// ranges, so a jump host and a target never land on the same port by accident.
enum ProxyHopFixturePorts {
    private static let jumpRange: ClosedRange<UInt16> = 25_500 ... 25_559
    private static let targetRange: ClosedRange<UInt16> = 25_600 ... 25_659

    struct Exhausted: Error {}

    static func claimPair() throws -> (jump: Int, target: Int) {
        guard let jump = SSHFixturePort.claim(in: jumpRange),
              let target = SSHFixturePort.claim(in: targetRange)
        else {
            throw Exhausted()
        }
        return (jump: Int(jump), target: Int(target))
    }
}
