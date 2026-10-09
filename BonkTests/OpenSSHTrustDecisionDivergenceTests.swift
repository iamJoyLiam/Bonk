import Crypto
import Foundation
import Testing
import Citadel
import NIOCore
@testable import Bonk

/// AUDIT-FIND-001, tier 2.
///
/// Tier 1 established what argv production hands to `ssh`
/// (`OpenSSHTrustPolicyArgvTests`). This tier establishes what the two
/// transports then *decide*, against one real server on one real port:
///
///     Bonk's store pinned to key A   +   server presents key B
///       native         → rejects   (A ≠ B, decided in HostKeyValidator)
///       compatibility  → accepts   (accept-new has never seen B, and writes
///                                     it into its own known_hosts)
///
/// The invariant under test: selecting the compatibility transport must not
/// change Bonk's host-key trust semantics. Current production violates it.
///
/// ## Why each leg is wired the way it is
///
/// **native** goes through `SSHNetworkService.connect`, the production entry
/// point, not a hand-built `HostKeyValidator`. `connect` → `establishConnection`
/// → `makeNativeClient` is where the pinned fingerprint is read out of
/// `hostKeyStore` and handed to the validator, so driving `SSHClient.connect`
/// directly would skip the very step under test and prove nothing about
/// production wiring.
///
/// **compatibility** goes through the real `OpenSSHBackend` against the real
/// `/usr/bin/ssh`, with only the trust store redirected to a temporary file via
/// `knownHostsPathOverride`. The argv is still built by production code.
///
/// ## Two harness traps this test is built to avoid
///
/// 1. `connect(config:)` on macOS routes `.password` to the compatibility
///    transport, and that branch `return`s *before attempting any connection*.
///    A test that only checked "did `connect` throw?" would see a throw-free
///    success and report ACCEPT. This test forces the native backend through the
///    production `setVNextPreferredBackend` API and then asserts
///    `usesOpenSSHTransport == false`, so the early return cannot be mistaken
///    for a decision.
///
/// 2. `connect(config:)` swallows non-`hostKeyMismatch` failures and kicks off
///    `startReconnect()` instead of throwing when `maxReconnectAttempts > 0`
///    (the default is 5). A genuine connection error would then read as a
///    successful connect. This test sets `maxReconnectAttempts: 0` so any
///    failure propagates, and asserts the thrown error is specifically
///    `hostKeyMismatch` — a rejection for some other reason would not be
///    evidence about the host-key decision.
///
/// ## Isolation
///
/// The compatibility leg records key B into a temporary `known_hosts` it owns.
/// The real `~/Library/Application Support/Bonk/known_hosts` is snapshotted
/// before and asserted byte-identical after. The native leg uses an in-memory
/// store, so `UserDefaults.standard` — where `PersistentHostKeyStore` lives —
/// is never touched at all.
///
/// ## Trace
///
/// Every run writes a trace to an absolute path (announced in the test output
/// and in the file's first line) recording what each leg observed. Passwords and
/// PEM blocks are stripped; host-key fingerprints are kept, because "which key
/// was pinned and which was presented" is the entire finding and a public key
/// is not a secret. The trace exists so a red baseline can be read instead of
/// re-guessed.
@Suite("AUDIT-FIND-001 tier 2 — the trust decision itself")
struct OpenSSHTrustDecisionDivergenceTests {
    private static let tracePath =
        "/tmp/bonk-audit-001-tier2-trace-\(ProcessInfo.processInfo.processIdentifier).txt"

    // Bounded per leg so a stuck authentication or PTY prompt fails with a
    // named stage instead of a generic suite timeout. Production already bounds
    // the native connect at 10s; these are deliberately looser.
    private static let nativeLegTimeout: Duration = .seconds(30)
    private static let compatLegTimeout: Duration = .seconds(45)
    private static let compatPollInterval: Duration = .milliseconds(100)

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tier2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    private func appSupportKnownHosts() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bonk/known_hosts")
            .path
    }

    private func snapshot(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// One server, one port, key B. Both legs talk to it.
    private func startServerKeyB() async throws -> BenchSSHServer.Instance {
        try await BenchSSHServer.start(
            hostKeySeed: 0x7C,
            password: BenchSSHServerSmokeTests.password,
            execDelegate: SubprocessExecDelegate(spawned: SpawnedProcesses())
        )
    }

    private func config(port: Int) -> SSHConnectionConfig {
        SSHConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(port),
            username: "bench",
            authMethod: .password(BenchSSHServerSmokeTests.password),
            // See trap 2: with the default of 5, a non-host-key failure would
            // start a reconnect and return normally instead of throwing.
            maxReconnectAttempts: 0,
            bypassControlMaster: true
        )
    }

    // MARK: - The gate

    @Test("Bonk-pinned A rejects key B while the compatibility transport accepts it")
    func trustDecisionsDivergeForTheSameHost() async throws {
        let trace = Tier2Trace(path: Self.tracePath, secrets: [BenchSSHServerSmokeTests.password])
        trace.line("TIER2-BEGIN")

        let server = try await startServerKeyB()
        defer { server.stop() }
        // Hoisted: `BenchSSHServer.Instance` is not Sendable, and the timeout
        // helper's operation is @Sendable.
        let port = server.port

        let realKnownHostsPath = appSupportKnownHosts()
        let realBefore = snapshot(realKnownHostsPath)
        trace.line("SERVER host=127.0.0.1 port=\(port) hostKey=B(seed=0x7C)")
        trace.line("APP-SUPPORT-KNOWN-HOSTS path=\(realKnownHostsPath) bytes=\(realBefore.utf8.count)")
        trace.line("SAME-INSTANT-OVERRIDE check=isolated-temp-store-per-leg")

        // --- native leg: Bonk believes A, server presents B -------------------
        trace.line("")
        trace.line("NATIVE-BEGIN")
        let pinnedA = SSHHostFingerprint(hash: "SHA256:" + String(repeating: "A", count: 43))
        let store = PinnedHostKeyStore(pinned: pinnedA)
        let service = SSHNetworkService(hostKeyStore: store)
        // Trap 1: without this, `.password` on macOS takes the compatibility
        // branch, which returns without connecting anything.
        await service.setVNextPreferredBackend(.native)
        trace.line("NATIVE-WIRING entry=SSHNetworkService.connect(forced=.native)")
        trace.line("NATIVE-PINNED key=A hash=\(pinnedA.hash)")

        let nativeOutcome: Tier2LegOutcome
        var nativeError: (any Error)?
        do {
            try await withThrowingTimeout(of: Self.nativeLegTimeout) {
                try await service.connect(config: config(port: port))
            }
            nativeOutcome = .accept(error: nil)
        } catch {
            nativeError = error
            nativeOutcome = .reject(error: Tier2Trace.describe(error))
        }

        // Typed, not string-matched. `String(describing:)` on this error gives
        // the enum case name (`hostKeyMismatch(expected:…, received:…)`), so any
        // substring assertion on a human-readable message would be asserting on
        // wording. Matching the case is both stronger and immune to that.
        var mismatch: SSHServiceError?
        if let serviceError = nativeError as? SSHServiceError, case .hostKeyMismatch = serviceError {
            mismatch = serviceError
        }

        // Both observables are Sendable, unlike the service's `client`. The
        // state is what distinguishes "the native path failed and cleaned up"
        // (disconnected) from "connect returned down the compatibility branch
        // and left the connection hanging" (connecting).
        let transport = await service.usesOpenSSHTransport
        let state = await service.connectionState
        trace.line("NATIVE-TRANSPORT usesOpenSSHTransport=\(transport) state=\(state)")
        trace.line("NATIVE-RESULT = \(nativeOutcome.result)")
        trace.line("NATIVE-ERROR  = \(nativeOutcome.error ?? "<none>")")
        if case let .hostKeyMismatch(expected, received) = mismatch {
            // The exact key the server offered, taken from the typed error
            // rather than parsed back out of a message string.
            trace.line("NATIVE-KEYS expected=A(\(expected)) received=B(\(received))")
        } else {
            trace.line("NATIVE-KEYS expected=A(n/a) received=B(n/a)")
        }
        trace.line("NATIVE-STORED key=\(await store.storedDescription())")
        trace.line("NATIVE-END")

        // --- compatibility leg: empty TOFU store, server presents B ----------
        trace.line("")
        trace.line("COMPAT-BEGIN")
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tempKnownHosts = dir.appendingPathComponent("known_hosts")
        try Data().write(to: tempKnownHosts)
        trace.line("KNOWN-HOSTS-BEFORE path=\(tempKnownHosts.path) \(Tier2KnownHosts.describe(snapshot(tempKnownHosts.path)))")

        let backend = try OpenSSHBackend(
            config: config(port: port), knownHostsPathOverride: tempKnownHosts.path
        )
        // Proves the override was honoured rather than silently ignored and the
        // backend quietly using the app-support file.
        #expect(
            backend.knownHostsPath == tempKnownHosts.path,
            "the backend must record host keys into the file this test owns, not \(backend.knownHostsPath)"
        )
        trace.line("COMPAT-WIRING backend=OpenSSHBackend knownHostsPath=\(backend.knownHostsPath)")
        trace.line("COMPAT-ARGV \(backend.sshArguments(pty: true, command: nil, additionalOptions: [], attemptID: "tier2-trace").joined(separator: " "))")

        let failureBox = Tier2FailureBox()
        let session = try backend.openPTY(
            cols: 80, rows: 24, termType: "xterm-256color",
            onExit: { failureBox.noteExit() },
            onFailure: { failureBox.record(failure: $0) }
        )
        defer {
            session.close()
            backend.close()
        }

        let compatOutcome = await Self.awaitCompatOutcome(
            knownHostsPath: tempKnownHosts.path,
            failureBox: failureBox
        )
        let recorded = snapshot(tempKnownHosts.path)
        trace.line("COMPAT-RESULT = \(compatOutcome.result)")
        trace.line("COMPAT-ERROR  = \(compatOutcome.error ?? "<none>")")
        trace.line("KNOWN-HOSTS-AFTER path=\(tempKnownHosts.path) \(Tier2KnownHosts.describe(recorded))")
        trace.line("COMPAT-END")

        session.close()
        backend.close()

        // --- isolation --------------------------------------------------------
        let realAfter = snapshot(realKnownHostsPath)
        trace.line("")
        trace.line("APP-SUPPORT-AFTER bytes=\(realAfter.utf8.count) unchanged=\(realAfter == realBefore)")
        trace.line("TIER2-END")
        trace.flush()

        // --- baseline ---------------------------------------------------------
        // The whole point: the same server, the same port, the same key — one
        // transport refused it and the other took it.

        #expect(
            nativeOutcome.result == "REJECT",
            """
            the native transport accepted a host key that differs from the one \
            Bonk has pinned. Either Bonk's own trust store is not being consulted, \
            or this leg never reached the trust decision — see the trace.
            """
        )

        // A rejection for a reason other than the host-key decision — a closed port, an
        // auth failure, the outer timeout — is not evidence about host keys, so
        // this asks the typed error rather than the verdict.
        #expect(
            mismatch != nil,
            """
            the native leg must have been rejected by the host-key decision \
            (`SSHServiceError.hostKeyMismatch`). Got a different error: \
            \(nativeOutcome.error.map { String(reflecting: type(of: $0 as Any)) } ?? "<none>") \
            — \(nativeOutcome.error ?? "<none>")
            """
        )

        // Trap 1 made observable. If `connect` had taken the compatibility
        // branch it would have returned without throwing *and* left the service
        // in `.connecting`, so a REJECT verdict could never have been reached —
        // but asserting it means the harness cannot quietly drift back into that
        // branch and report ACCEPT off a no-op connect.
        #expect(
            transport == false && state == .disconnected,
            """
            the native leg must have run the native transport and cleaned up \
            after its failure. observed usesOpenSSHTransport=\(transport) \
            state=\(state)
            """
        )

        let nativeStored = await store.storedDescription()
        #expect(
            nativeStored.contains("saved=none"),
            "a rejected connection must not have written trust state; store reports \(nativeStored)"
        )

        #expect(
            compatOutcome.result == "ACCEPT",
            """
            the compatibility transport must accept an unseen key under the \
            current accept-new policy. If it rejected, the policy changed and \
            this gate needs re-reading rather than re-asserting.
            """
        )

        let recordedEntries = Tier2KnownHosts.parse(recorded)
        #expect(
            recordedEntries.count == 1,
            "the compatibility transport should record exactly the one key it accepted; got \(recordedEntries.count)"
        )

        // Both legs met the same key — checked from values the harness actually holds,
        // not parsed back out of a message. The `nil` preconditions are asserted
        // rather than used as an implicit skip: a cross-check that quietly does
        // not run is the same failure mode as a test that quietly did not run.
        let presentedB: String?
        if case let .hostKeyMismatch(_, received) = mismatch {
            presentedB = received
        } else {
            presentedB = nil
        }
        let recordedB = recordedEntries.first?.fingerprint

        #expect(
            presentedB != nil,
            "the native leg's typed error must expose the key the server offered, or the cross-check below proves nothing"
        )
        #expect(
            recordedB != nil,
            "the compatibility leg must record a parseable entry, or the cross-check below proves nothing"
        )

        if let presentedB, let recordedB {
            // If these differ, the message separates "different keys" from
            // "same key, different fingerprint formatting" — a different problem
            // entirely, and one the trace makes visible.
            #expect(
                presentedB == recordedB,
                """
                both legs must have been offered the same server key. \
                native saw \(presentedB), compatibility recorded \(recordedB).
                """
            )
        }

        #expect(
            realAfter == realBefore,
            """
            this test must not create persistent host-key state in Application \
            Support; \(realKnownHostsPath) changed
            """
        )
    }

    /// Bounded wait for ssh to make its host-key decision.
    ///
    /// `openPTY` returns as soon as the process is spawned, so the decision has
    /// not happened yet. Two independent signals end the wait: ssh rejecting the
    /// key (reported through `onFailure` as `.hostKey`), or ssh accepting it
    /// (which it records in known_hosts *before* authentication completes). A
    /// deadline means a wedged PTY or prompt reports a named stage rather than
    /// hanging the suite.
    private static func awaitCompatOutcome(
        knownHostsPath: String,
        failureBox: Tier2FailureBox
    ) async -> Tier2LegOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: compatLegTimeout)

        func currentEntries() -> [Tier2KnownHosts.Entry] {
            Tier2KnownHosts.parse((try? String(contentsOfFile: knownHostsPath, encoding: .utf8)) ?? "")
        }

        while clock.now < deadline {
            if failureBox.sawHostKeyRejection {
                return .reject(error: failureBox.describeHostKeyFailure())
            }
            // Accepted: ssh has durably written the key it trusted.
            if !currentEntries().isEmpty {
                return .accept(error: nil)
            }
            if failureBox.sawExit {
                return .inconclusive(
                    error: "ssh exited (\(failureBox.describeExitFailure())) without a host-key decision"
                )
            }
            try? await Task.sleep(for: compatPollInterval)
        }

        if !currentEntries().isEmpty { return .accept(error: nil) }
        if failureBox.sawHostKeyRejection { return .reject(error: failureBox.describeHostKeyFailure()) }
        return .inconclusive(error: "no host-key decision observed within \(compatLegTimeout)")
    }
}

// MARK: - Outcomes

/// What one leg concluded. `INCONCLUSIVE` is deliberately distinct from both
/// ACCEPT and REJECT: it is the state a wedged or misconfigured leg lands in,
/// and collapsing it into either of the other two is how a broken harness gets
/// reported as a security result.
enum Tier2LegOutcome {
    case accept(error: String?)
    case reject(error: String?)
    case inconclusive(error: String)

    var result: String {
        switch self {
        case .accept: "ACCEPT"
        case .reject: "REJECT"
        case .inconclusive: "INCONCLUSIVE"
        }
    }

    var error: String? {
        switch self {
        case let .accept(error), let .reject(error): error
        case let .inconclusive(error): error
        }
    }
}

// MARK: - In-memory store: pinned to A, records nothing

/// Pins every host to `pinned` and remembers any write, in memory.
///
/// In memory is the point. `PersistentHostKeyStore` has no injectable storage and
/// reads/writes `UserDefaults.standard` in `init`/`saveFingerprint`, so using it
/// here would mean reading and rewriting the developer's real trust state — a
/// test that changes global state on the machine it runs on.
actor PinnedHostKeyStore: SSHHostKeyStore {
    private let pinned: SSHHostFingerprint?
    private var saved: [String: SSHHostFingerprint] = [:]

    init(pinned: SSHHostFingerprint?) {
        self.pinned = pinned
    }

    func knownFingerprint(for host: String, port: UInt16) async -> SSHHostFingerprint? {
        pinned
    }

    func saveFingerprint(_ fingerprint: SSHHostFingerprint, for host: String, port: UInt16) async {
        saved["\(host):\(port)"] = fingerprint
    }

    /// What the store would report about itself, for the trace and the
    /// assertion that a rejected connection wrote no trust state.
    func storedDescription() -> String {
        if saved.isEmpty { return "pinned=A saved=none" }
        return "pinned=A saved=\(saved.keys.sorted().joined(separator: ","))"
    }
}

// MARK: - known_hosts reading

enum Tier2KnownHosts {
    struct Entry {
        let hosts: String
        let keyType: String
        let blob: String

        /// Same computation OpenSSH and `HostKeyValidator` both perform:
        /// base64(SHA256(wire-format public key)), `=` stripped.
        var fingerprint: String {
            guard let key = Data(base64Encoded: blob) else { return "SHA256:<undecodable>" }
            return "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
    }

    static func parse(_ text: String) -> [Entry] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(separator: " ").map(String.init)
            guard fields.count >= 3 else { return nil }
            return Entry(hosts: fields[0], keyType: fields[1], blob: fields[2])
        }
    }

    /// Compact, non-sensitive description for the trace: which hosts, how many
    /// entries, and the fingerprint of each — never the raw key blob.
    static func describe(_ text: String) -> String {
        let entries = parse(text)
        guard !entries.isEmpty else { return "entries=0" }
        let described = entries.map { "\($0.hosts)[\($0.keyType)] \($0.fingerprint)" }
        return "entries=\(entries.count) \(described.joined(separator: " "))"
    }
}

// MARK: - Failure capture for the compatibility leg

/// Collects what the OpenSSH transport reported, so "rejected on host key" is
/// distinguishable from "failed to authenticate" and from "exited silently".
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

    /// One line per observed failure, so the trace shows what the transport
    /// actually said rather than a bare verdict.
    func describeHostKeyFailure() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure.map { Tier2Trace.describe($0) } ?? "host key rejected (no detail captured)"
    }

    func describeExitFailure() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure.map { Tier2Trace.describe($0) } ?? "no failure detail"
    }
}

// MARK: - Trace

/// Appends to an absolute-path trace file.
///
/// Deliberately simple and deliberately dumb about secrets: everything written
/// passes through `redact`, which strips PEM blocks and replaces known secrets.
/// Host-key fingerprints survive that filter on purpose — they are public, and
/// they are the finding.
final class Tier2Trace: @unchecked Sendable {
    private let path: String
    private let secrets: [String]
    private let lock = NSLock()
    private var buffer = ""
    private var wroteHeader = false

    init(path: String, secrets: [String]) {
        self.path = path
        self.secrets = secrets
    }

    var filePath: String { path }

    func line(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if !wroteHeader {
            wroteHeader = true
            buffer += "# trace=\(path)\n"
        }
        buffer += redact(text) + "\n"
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        try? buffer.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A stable one-line description of an error, with ANSI and control
    /// characters removed so the trace stays greppable.
    static func describe(_ error: some Error) -> String {
        let text = "\(error)"
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    func redact(_ text: String) -> String {
        var out = text
        // PEM blocks wholesale: nothing in this test needs key material, and a
        // trace is the last place it should ever appear.
        out = out.replacingOccurrences(
            of: #"-----BEGIN[^-]*-----[\s\S]*?-----END[^-]*-----"#,
            with: "<redacted-pem>",
            options: .regularExpression
        )
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return out
    }
}