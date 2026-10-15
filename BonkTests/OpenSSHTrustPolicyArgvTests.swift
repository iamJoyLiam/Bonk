import Foundation
import Testing
import NIOCore
@testable import Bonk

/// Records every launch, then performs it.
///
/// Delegating to the real spawner matters: the process genuinely starts and the
/// argv captured is the one production passed, not a reconstruction of what it
/// should have passed.
final class RecordingOpenSSHProcessSpawner: OpenSSHProcessSpawning, @unchecked Sendable {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var stored: [Invocation] = []

    /// When true, record the real argv but spawn `/usr/bin/true` instead.
    ///
    /// ## Why this exists
    ///
    /// The original version recorded *and* really launched `ssh`. That was fine
    /// for a direct connection — ssh fails fast against a fixture. It is not fine
    /// for a jump-host argv, whose `ProxyCommand` carries `-W %h:%p`: the inner
    /// ssh blocks waiting on a forwarding channel the bench fixture never
    /// services, and the resulting process outlives the test.
    ///
    /// The cost was not hypothetical. Those orphans accumulated across runs,
    /// pinned PTYs, and wedged later runs — `BenchSSHServerSmokeTests`, which
    /// shares nothing with this code, stopped completing at all until they were
    /// killed by hand. A test that only reads argv has no reason to make a real
    /// connection, and a test that makes one has to clean it up.
    ///
    /// So argv gates record only. Any gate that genuinely needs a live
    /// connection must construct the default spawner and close its backend.
    let recordOnly: Bool

    init(recordOnly: Bool = false) {
        self.recordOnly = recordOnly
    }

    var recorded: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func spawn(
        executable: String,
        arguments: [String],
        cols: Int,
        rows: Int,
        termType: String,
        environment: [String: String]
    ) throws -> OpenSSHProcessTransport {
        lock.lock()
        stored.append(Invocation(executable: executable, arguments: arguments))
        lock.unlock()

        if recordOnly {
            // A real transport that exits immediately, so the caller gets a
            // well-formed object without an unkillable network process behind it.
            return try DefaultOpenSSHProcessSpawner().spawn(
                executable: "/usr/bin/true",
                arguments: [],
                cols: cols, rows: rows, termType: termType, environment: [:]
            )
        }

        return try DefaultOpenSSHProcessSpawner().spawn(
            executable: executable, arguments: arguments,
            cols: cols, rows: rows, termType: termType, environment: environment
        )
    }

    /// The connection launch, identified by executable *and* by carrying this
    /// host's port. `ssh` is also invoked for auxiliary work, and asserting on
    /// "the first capture" would be asserting on whichever one happened to land
    /// first.
    func connectionInvocation(port: Int, executable: String = "/usr/bin/ssh") -> Invocation? {
        recorded.first {
            $0.executable == executable
                && $0.arguments.contains("-p")
                && $0.arguments.contains(String(port))
        }
    }
}

/// AUDIT-FIND-001, tier 1.
///
/// Establishes that the argv production hands to `ssh` carries the current
/// host-key trust policy, observed at `OpenSSHProcessTransport.spawn` — the
/// launch boundary every connection, command, SFTP and forward goes through.
///
/// This proves production wiring only. It does **not** prove what ssh then
/// decides; that is tier 2, where a pinned key and a presented key diverge. Do
/// not read a green run here as AUDIT-FIND-001 verified.
@Suite("AUDIT-FIND-001 tier 1 — trust policy reaches ssh")
struct OpenSSHTrustPolicyArgvTests {
    @Test("The connection argv handed to ssh carries the current trust policy")
    func connectionArgvCarriesTrustPolicy() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0x5A,
            password: BenchSSHServerSmokeTests.password,
            execDelegate: SubprocessExecDelegate(spawned: SpawnedProcesses())
        )
        defer { server.stop() }

        let recorder = RecordingOpenSSHProcessSpawner(recordOnly: true)
        // Defaults chosen deliberately: `bypassControlMaster` so the launch is
        // the connection itself rather than a multiplexed reuse, and no algorithm
        // override so the captured argv is the system-default policy.
        let config = SSHConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(server.port),
            username: "bench",
            authMethod: .password(BenchSSHServerSmokeTests.password),
            bypassControlMaster: true
        )
        // A temp store, always: the default resolver is the user's real
        // Application Support trust store, and first-contact resolution would
        // write this fixture server's key into it.
        let (resolver, resolverDir) = try HostKeyFixtureSupport.tempResolver(label: "argv")
        defer { try? FileManager.default.removeItem(at: resolverDir) }
        let backend = try OpenSSHBackend(
            config: config, spawner: recorder, knownHostsResolver: resolver
        )

        // The launch happens inside openPTY, before any handshake outcome. A
        // connection that later fails still tells us what argv was used, so the
        // failure is deliberately swallowed.
        _ = try? await backend.openPTY(cols: 80, rows: 24, termType: "xterm-256color", onExit: {})

        let invocation = try #require(
            recorder.connectionInvocation(port: server.port),
            """
            no /usr/bin/ssh connection launch for port \(server.port) was \
            recorded; captured: \(recorder.recorded.map { $0.executable })
            """
        )
        let arguments = invocation.arguments

        #expect(
            arguments.contains { $0 == "StrictHostKeyChecking=yes" },
            """
            the connection must carry strict host-key checking. The fix is not \
            the string itself but the chain behind it: canonical CAS -> \
            generated known_hosts -> strict verification. argv: \(arguments)
            """
        )
        #expect(
            !arguments.contains { $0.contains("StrictHostKeyChecking=accept-new") },
            "AUDIT-FIND-001: accept-new must not be reintroduced; argv: \(arguments)"
        )

        let knownHosts = arguments.first { $0.hasPrefix("UserKnownHostsFile=") }
        let knownHostsPath = try #require(
            knownHosts?.replacingOccurrences(of: "UserKnownHostsFile=", with: ""),
            "the connection must name a UserKnownHostsFile; argv: \(arguments)"
        )
        #expect(!knownHostsPath.isEmpty, "UserKnownHostsFile must not be empty")
        // An app-private path, not asserted to any particular directory: the
        // property is that the trust store is the app's own rather than the
        // user's or the system's.
        #expect(
            !knownHostsPath.hasSuffix("/.ssh/known_hosts"),
            "the compatibility path must not defer to the user's known_hosts"
        )
        #expect(
            arguments.contains("GlobalKnownHostsFile=/dev/null"),
            "system-wide known_hosts must stay disabled for this trust store to be the only one"
        )
    }

    /// AUDIT-FIND-001 regression gate.
    ///
    /// This suite previously asserted the opposite — that argv carried
    /// `StrictHostKeyChecking=accept-new` — and was the tier-1 evidence that the
    /// finding was real. That evidence now lives in commit `889325e1` and in
    /// `docs/security-audit.md`; what remains here is the assertion that the defect
    /// cannot come back unnoticed.
    ///
    /// `connectionArgvCarriesTrustPolicy` above already fails if `accept-new`
    /// returns, so restoring the old behaviour turns that gate red too. This test
    /// exists separately so the intent is unmistakable to a reader who never saw
    /// the finding, and so the chain is: commit + ledger + this gate.
    @Test("AUDIT-FIND-001: accept-new is not reintroduced into the connection argv")
    func auditFind001IsNotReintroduced() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0x6B,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { server.stop() }

        let recorder = RecordingOpenSSHProcessSpawner(recordOnly: true)
        let config = SSHConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(server.port),
            username: "bench",
            authMethod: .password(BenchSSHServerSmokeTests.password),
            bypassControlMaster: true
        )
        // A temp store, always: the default resolver is the user's real
        // Application Support trust store, and first-contact resolution would
        // write this fixture server's key into it.
        let (resolver, resolverDir) = try HostKeyFixtureSupport.tempResolver(label: "argv")
        defer { try? FileManager.default.removeItem(at: resolverDir) }
        let backend = try OpenSSHBackend(
            config: config, spawner: recorder, knownHostsResolver: resolver
        )
        _ = try? await backend.openPTY(cols: 80, rows: 24, termType: "xterm-256color", onExit: {})

        let invocation = try #require(
            recorder.connectionInvocation(port: server.port),
            "no /usr/bin/ssh connection launch was recorded; captured: \(recorder.recorded.map { $0.executable })"
        )
        #expect(
            !invocation.arguments.contains { $0.contains("StrictHostKeyChecking=accept-new") },
            """
            AUDIT-FIND-001 has been reintroduced: this connection would accept-new \
            an unknown key instead of verifying it against the canonical store. \
            argv: \(invocation.arguments)
            """
        )
    }

    /// The trust file must be a real file, carrying the pinned key, at the moment
    /// ssh is launched.
    ///
    /// This closes the gap that let the convergence gate pass for the wrong
    /// reason. Asserting that argv *names* a `UserKnownHostsFile` is satisfied by a
    /// path that does not exist — and with `StrictHostKeyChecking=yes`, a missing
    /// trust file and a substituted key produce the same refusal. A gate that only
    /// checks the string cannot tell those two apart, so both a refusal and a
    /// success look identical to it.
    ///
    /// What distinguishes them is the file. This gate reads the exact path
    /// production handed to ssh and requires it to exist and to contain the key
    /// the canonical store holds. If the rendered file is missing, or empty, or
    /// was written and then deleted, this goes red — and the convergence gate can
    /// no longer be satisfied by a failure for the wrong reason.
    @Test("the generated trust file exists and carries the canonical key at launch")
    func resolverGeneratedTrustFileIsUsableAtLaunch() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0x6B,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { server.stop() }

        // Seed a temp canonical store with the key this server really serves, so
        // resolution takes the "record exists → render" branch. No override: the
        // resolver must do the work.
        let dir = try HostKeyFixtureSupport.makeTempDir("argv-realfile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        let pinned = try HostKeyFixtureSupport.scannedKey(port: UInt16(server.port))
        #expect(try store.recordIfAbsentOrMatching(
            host: "127.0.0.1", port: UInt16(server.port), candidate: pinned
        ) != .persistenceFailure, "seeding the canonical store failed")

        let recorder = RecordingOpenSSHProcessSpawner(recordOnly: true)
        let config = SSHConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(server.port),
            username: "bench",
            authMethod: .password(BenchSSHServerSmokeTests.password),
            bypassControlMaster: true
        )
        let backend = try OpenSSHBackend(
            config: config,
            spawner: recorder,
            knownHostsResolver: OpenSSHKnownHostsResolver(store: store)
        )
        defer { backend.close() }
        _ = try? await backend.openPTY(cols: 80, rows: 24, termType: "xterm-256color", onExit: {})

        let invocation = try #require(
            recorder.connectionInvocation(port: server.port),
            "no /usr/bin/ssh connection launch was recorded; captured: \(recorder.recorded.map { $0.executable })"
        )
        let named = try #require(
            invocation.arguments.first { $0.hasPrefix("UserKnownHostsFile=") },
            "no UserKnownHostsFile in argv: \(invocation.arguments)"
        )
        let path = try #require(
            named.replacingOccurrences(of: "UserKnownHostsFile=", with: ""),
            "could not read the trust file path out of \(named)"
        )

        // The file must exist. This is the assertion whose absence let a deleted
        // trust file read as a successful host-key refusal.
        #expect(
            FileManager.default.fileExists(atPath: path),
            """
            the resolver handed ssh a UserKnownHostsFile that does not exist. With \
            StrictHostKeyChecking=yes this fails closed, and it is indistinguishable \
            at the message level from a genuine key mismatch — so any gate that \
            only checks the refusal will pass for the wrong reason. path: \(path)
            """
        )

        guard FileManager.default.fileExists(atPath: path) else { return }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!contents.isEmpty, "the generated trust file is empty: \(path)")
        // It must carry the key the store pinned, not merely exist.
        let blob = pinned.keyBlob.base64EncodedString()
        #expect(
            contents.contains(blob),
            """
            the generated trust file does not contain the canonical key. \
            pinned=\(pinned.fingerprint.hash) contents=<\(contents)>
            """
        )
    }
}
