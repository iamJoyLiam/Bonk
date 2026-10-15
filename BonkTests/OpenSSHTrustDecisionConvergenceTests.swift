import Foundation
import Testing
import Citadel
import NIOCore
@testable import Bonk

/// AUDIT-FIND-001, tier 2 — now a **convergence** gate.
///
/// ## Historical semantics, deliberately preserved
///
/// This file previously asserted the *opposite* of what it asserts now. It was
/// the tier-2 evidence that AUDIT-FIND-001 was real: given one server on one
/// port with Bonk pinned to key A while the server presented key B, the native
/// transport rejected and the compatibility transport **accepted and recorded** B.
/// The two transports kept independent host-key trust state, so a detected MITM
/// became a silent one.
///
/// That evidence is not discarded. It stands in:
///
///   - commit `889325e1` — the divergence baseline, its designated mutation, and
///     the pristine restore
///   - `docs/security-audit.md` — AUDIT-FIND-001 in the ledger
///   - `OpenSSHTrustPolicyArgvTests.auditFind001IsNotReintroduced` — the gate that
///     fails if `accept-new` returns
///   - this file — the gate that fails if the two transports stop agreeing
///
/// Deleting the old assertion without those would leave the audit with no live
/// proof of the finding; that is why the suite is converted rather than removed.
///
/// ## What is asserted now
///
/// The same substitution scenario, run through the real production chain on both
/// transports. The property is convergence: both refuse the same key, and neither
/// writes trust state for the key they refused.
@Suite("AUDIT-FIND-001 tier 2 — the transports converge on one trust decision")
struct OpenSSHTrustDecisionConvergenceTests {
    private static let tracePath =
        "/tmp/bonk-audit-001-convergence-\(ProcessInfo.processInfo.processIdentifier).txt"

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("converge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// The production canonical store — the file this test must never write.
    private func productionCanonicalStorePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bonk/host_key_records.json")
            .path
    }

    /// The server's real key material, obtained the way production obtains it:
    /// `ssh-keyscan`. Nothing about it is trusted here; it is only the bytes the
    /// server actually serves.
    private func scannedKey(port: UInt16) throws -> HostKeyRecord {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", "10", "-t", "ed25519", "-p", String(port), "127.0.0.1"]
        var environment = ProcessInfo.processInfo.environment
        environment = ["PATH": environment["PATH"] ?? "/usr/bin:/bin", "LC_ALL": "C"]
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard let line = text.components(separatedBy: .newlines).first(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
            return trimmed.split(separator: " ").count >= 3
        }) else {
            throw ConvergenceFixtureError.noKey
        }
        let fields = line.split(separator: " ").map(String.init)
        guard let blob = Data(base64Encoded: fields[2]),
              let parsed = HostKeyBlob.parse(blob)
        else {
            throw ConvergenceFixtureError.noKey
        }
        return HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: .nativeAndOpenSSH
        )
    }

    enum ConvergenceFixtureError: Error { case noKey, noFreePort }

    // MARK: - The gate

    @Test("both transports reject the same substituted key, and neither records it")
    func bothTransportsConvergeOnTheSameRefusal() async throws {
        let trace = Tier2Trace(path: Self.tracePath, secrets: [BenchSSHServerSmokeTests.password])
        trace.line("CONVERGENCE-BEGIN")

        // Claim one port and reuse it: a host key only counts as "changed" from
        // ssh's point of view when the same host:port presents a different one.
        guard let claimed = SSHFixturePort.claim(in: BenchSSHServer.ports) else {
            throw ConvergenceFixtureError.noFreePort
        }
        let port = Int(claimed)

        // --- Phase A: the trusted key. Seed the canonical store with it. ---
        let serverA = try await BenchSSHServer.start(
            hostKeySeed: 0x5A,
            password: BenchSSHServerSmokeTests.password,
            port: port,
            sftpDelegate: BenchSFTPDelegate()
        )
        let trusted = try await scannedKey(port: UInt16(port))
        // Must wait for the listener to be released: phase B binds the same port
        // with a different key, and binding it while phase A's socket is still
        // open fails with EADDRINUSE.
        await serverA.stopAndWait()

        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(
            fileURL: dir.appendingPathComponent("records.json")
        )
        let seeded = try store.recordIfAbsentOrMatching(
            host: "127.0.0.1", port: UInt16(port), candidate: trusted
        )
        #expect(seeded == .inserted || seeded == .alreadyMatching,
                "the canonical store must accept the seeded key; got \(seeded)")
        trace.line("SEEDED key=A hash=\(trusted.fingerprint.hash) store=\(seeded.rawValue)")

        // Snapshot the *canonical* store, not the legacy known_hosts file. The
        // canonical store is what the resolver reads and writes; asserting on the
        // legacy file proved nothing while the resolver was busy rewriting the
        // real trust state.
        let productionStoreURL = URL(fileURLWithPath: productionCanonicalStorePath())
        let realBefore = (try? Data(contentsOf: productionStoreURL)) ?? Data()

        // --- Phase B: the same port, a different key. ---
        let serverB = try await BenchSSHServer.start(
            hostKeySeed: 0x7C,
            password: BenchSSHServerSmokeTests.password,
            port: port,
            execDelegate: SubprocessExecDelegate(spawned: SpawnedProcesses()),
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { serverB.stop() }

        // --- modern leg: native/Citadel, pinned to A, server presents B. ---
        let modernStore = PinnedHostKeyStore(pinned: trusted.fingerprint)
        let modernService = SSHNetworkService(hostKeyStore: modernStore)
        await modernService.setVNextPreferredBackend(.native)
        var modernOutcome = "connectedUnexpectedly"
        do {
            try await withThrowingTimeout(of: .seconds(30)) {
                try await modernService.connect(config: config(port: port))
            }
        } catch {
            modernOutcome = Tier2Trace.describe(error)
        }
        let modernRejected = modernOutcome.contains("hostKeyMismatch")
        trace.line("MODERN outcome=\(modernRejected ? "REJECT" : modernOutcome)")

        // --- compatibility leg: resolver renders A, real ssh verifies strictly. ---
        // No `knownHostsPathOverride`: the point is to exercise the resolver, so
        // the canonical record is what decides what ssh is told to trust.
        // The seeded store MUST be injected here. Without it the backend falls
        // back to the production canonical store in Application Support, which
        // means the "target" leg resolves by first-contact probe against whatever
        // key the server currently presents — so it accepts, and silently
        // persists that key into the user's real trust store. That is not a test
        // failure; it is the test writing user trust state, which the project
        // rules forbid outright.
        let compatBackend = try OpenSSHBackend(
            config: config(port: port),
            knownHostsResolver: OpenSSHKnownHostsResolver(store: store)
        )
        let failureBox = Tier2FailureBox()
        let session = try await compatBackend.openPTY(
            cols: 80, rows: 24, termType: "xterm-256color",
            onExit: { failureBox.noteExit() },
            onFailure: { failureBox.record(failure: $0) }
        )
        // Bounded wait: ssh reports the refusal asynchronously, and an unbounded
        // poll would hang the suite rather than fail it. `Task.sleep` because
        // `Thread.sleep` is unavailable from an async context.
        let compatDeadline = Date().addingTimeInterval(30)
        while Date() < compatDeadline, !failureBox.sawHostKeyRejection {
            try? await Task.sleep(for: .milliseconds(50))
        }
        session.close()
        compatBackend.close()

        let compatRejected = failureBox.sawHostKeyRejection
        trace.line("COMPAT outcome=\(compatRejected ? "REJECT" : "no host-key refusal") detail=\(failureBox.describeHostKeyFailure())")

        // --- trust state must be unchanged on both sides. ---
        let storeAfter = try store.lookup(host: "127.0.0.1", port: UInt16(port)).record
        #expect(storeAfter == trusted,
                "the canonical store must still hold key A; it was rewritten to \(storeAfter?.fingerprint.hash ?? "nil")")
        let realAfter = (try? Data(contentsOf: productionStoreURL)) ?? Data()
        #expect(realAfter == realBefore,
                """
                the production canonical store was modified by this test. A host-key \
                audit fixture that persists trust state into Application Support is \
                writing to the user's real trust store.
                """)

        trace.line("APP-SUPPORT unchanged=\(realAfter == realBefore)")
        trace.line("CONVERGENCE-END")
        trace.flush()

        // The convergence property, stated directly.
        #expect(
            modernRejected && compatRejected,
            """
            the two transports must agree on this host key. native rejected: \
            \(modernRejected); compatibility rejected: \(compatRejected). \
            A disagreement is AUDIT-FIND-001 open again.
            """
        )

        // ...and the refusal must be the right refusal.
        //
        // This is the assertion whose absence made the gate satisfiable for the
        // wrong reason. ssh reports "Host key verification failed." both when the
        // presented key differs from the pin and when the trust file is missing or
        // unreadable. An earlier revision of this suite passed while the resolver
        // was handing ssh a deleted file — the compat leg "rejected" because it
        // had nothing to verify against, not because it caught a substitution.
        //
        // "REMOTE HOST IDENTIFICATION HAS CHANGED" is ssh's message for a key
        // that does not match an entry it already had. Requiring it means this
        // gate can only be satisfied by a trust file that was actually read and
        // actually rejected.
        #expect(
            failureBox.describeHostKeyFailure().contains("REMOTE HOST IDENTIFICATION HAS CHANGED"),
            """
            the compatibility leg refused, but not for the reason under test. \
            A missing or unreadable trust file produces the same refusal as a \
            genuine mismatch, so this message is what distinguishes them. \
            detail: \(failureBox.describeHostKeyFailure())
            """
        )
    }

    private func config(port: Int) -> SSHConnectionConfig {
        SSHConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(port),
            username: "bench",
            authMethod: .password(BenchSSHServerSmokeTests.password),
            maxReconnectAttempts: 0,
            bypassControlMaster: true
        )
    }
}

/// Collects what the compatibility transport reported, so a host-key refusal is
/// distinguishable from an auth or exit failure.
final class Tier2FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: SSHFailure?
    private var sawHostKey = false
    private var exited = false

    func record(failure: SSHFailure) {
        lock.lock()
        defer { lock.unlock() }
        storedFailure = failure
        if case .hostKey = failure { sawHostKey = true }
    }

    func noteExit() {
        lock.lock()
        defer { lock.unlock() }
        exited = true
    }

    var sawHostKeyRejection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawHostKey
    }

    var sawExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    func describeHostKeyFailure() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure.map { Tier2Trace.describe($0) } ?? "<none>"
    }
}