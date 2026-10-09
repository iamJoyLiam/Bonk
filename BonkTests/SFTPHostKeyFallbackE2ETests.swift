import Foundation
import Testing
import Citadel
import NIOCore
@testable import Bonk

/// B-02, end-to-end.
///
/// B-02's *policy* is verified elsewhere: `SFTPBackendFallbackTests` drives
/// `SFTPBackendFallback.run` with observable legs, and it has been
/// mutation-proven. That is not the same claim. A pure predicate can be correct
/// while the orchestration around it is wrong, and AUDIT-FIND-001 is now direct
/// evidence that the thing being protected is real: given one server on one
/// port, the two transports do accept and reject different host keys. If this
/// service's fallback orchestration ever regressed, the consequence is precisely
/// that — the second transport persisting the key the first one rejected.
///
/// So this suite drives the real production chain and nothing simulated:
///
///     SFTPService.connect(using: SSHNetworkService)
///       -> SFTPBackendFallback.run                        SFTPBackendFallback.swift:82
///          -> connectCitadelLeg                          SFTPService.swift:152
///             -> SSHNetworkService.openSFTPClient()       SSHNetworkService.swift:352
///                -> makeNativeClient -> HostKeyValidator -> hostKeyMismatch
///          [ the OpenSSH leg must not consult its own store ]  SFTPService.swift:179
///
/// `SFTPMatrixLocalTests.testServiceHostKeyMismatchDoesNotFallBack` covers the
/// same rule but needs a bench server on tcp:2222, so it has never run here.
/// This suite runs the same contract against `BenchSSHServer`, which is
/// in-process and needs no fixed port, so the gate is runnable rather than
/// skipped.
///
/// ## The designated assertion, and why it is that one
///
/// When the fallback is permitted, `SFTPBackendFallback.run` still throws the
/// *original* trust error if the fallback leg itself fails
/// (`SFTPBackendFallback.swift:100`). So "did `connect` throw?" cannot detect
/// the regression — it stays green while the attacker's key is being written to
/// disk underneath it.
///
/// What the regression actually does is let the second transport consult, and
/// persist, a key the first transport rejected. That side effect is directly
/// observable in the second transport's trust store, so that is the designated
/// assertion. The other three assertions in the contract — a real SFTP
/// operation, a native host-key mismatch, the original trust error reaching the
/// caller — are asserted too, and all three stay green under mutation by design.
@Suite("B-02 E2E — a host-key failure must not reach the second transport")
struct SFTPHostKeyFallbackE2ETests {
    /// The second transport writes the key it accepted within a second or two of
    /// starting, and at baseline `connect` returns pre-auth in milliseconds, so
    /// 30s is generous for both. It deliberately does **not** exceed
    /// `runSFTP`'s own 120s readiness deadline: that deadline is only consulted
    /// when a chunk arrives, so a fallback leg blocked on its password prompt
    /// never reaches it and never resolves. Waiting for it would buy nothing —
    /// and under `withThrowingTimeout` it bought a wedged session, because that
    /// helper's task group will not return while its loser is stuck.
    private static let legTimeout: Duration = .seconds(30)

    /// One file per test. Both tests run in one process and `Tier2Trace` truncates
    /// on flush, so a shared path would let whichever finished last erase the
    /// other's evidence.
    private static func tracePath(_ name: String) -> String {
        "/tmp/bonk-b02-e2e-trace-\(name)-\(ProcessInfo.processInfo.processIdentifier).txt"
    }

    private static let appSupportKnownHosts: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bonk/known_hosts")
            .path
    }()

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("b02-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    private func bytes(of path: String) -> Data {
        (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    }

    /// One server with key B and a live SFTP subsystem. The subsystem matters:
    /// the gate below is only meaningful if the OpenSSH leg *could* have
    /// succeeded. A server that refused every SFTP operation would make the
    /// fallback fail for uninteresting reasons, and a failing fallback never
    /// writes a key — so the designated assertion would stay green under
    /// mutation and the gate would prove nothing.
    private func startServer() async throws -> BenchSSHServer.Instance {
        try await BenchSSHServer.start(
            hostKeySeed: 0x5A,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
    }

    private func config(port: Int) -> SSHConnectionConfig {
        SSHConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(port),
            username: "bench",
            authMethod: .password(BenchSSHServerSmokeTests.password),
            // Any failure must propagate instead of starting a reconnect, so a
            // host-key rejection cannot be reported as a successful connect.
            maxReconnectAttempts: 0,
            // The OpenSSH leg must be a real connection launch, not a
            // multiplexed reuse of someone else's.
            bypassControlMaster: true
        )
    }

    /// A session wired so that *both* transports are genuinely available: the
    /// compatibility transport is forced explicitly rather than reached by
    /// accident, because `.password` on macOS happens to route there and would
    /// otherwise set this up through an early return that connects nothing.
    private func makeSession(
        store: any SSHHostKeyStore,
        knownHostsOverride: String,
        port: Int
    ) async throws -> SSHNetworkService {
        let ssh = SSHNetworkService(hostKeyStore: store)
        await ssh.setVNextPreferredBackend(.compatibility)
        await ssh.setOpenSSHKnownHostsPathOverride(knownHostsOverride)
        try await ssh.connect(config: config(port: port))
        return ssh
    }

    // MARK: - Control

    /// The production chain is live: unpinned store, real server, real SFTP, and
    /// it reaches the filesystem through the Citadel leg.
    ///
    /// This is what stops the gate from passing for the wrong reason. A fixture
    /// that could not serve SFTP at all would produce a host-key rejection
    /// indistinguishable from a broken chain.
    @Test("control: the unpinned production chain reaches the filesystem")
    func unpinnedStoreReachesTheFilesystem() async throws {
        let trace = Tier2Trace(path: Self.tracePath("control"), secrets: [BenchSSHServerSmokeTests.password])
        trace.line("B02-CONTROL-BEGIN")

        let server = try await startServer()
        defer { server.stop() }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let knownHosts = dir.appendingPathComponent("known_hosts").path
        try Data().write(to: URL(fileURLWithPath: knownHosts))

        let appSupportBefore = bytes(of: Self.appSupportKnownHosts)
        let store = PinnedHostKeyStore(pinned: nil)
        let ssh = try await makeSession(
            store: store, knownHostsOverride: knownHosts, port: server.port
        )
        trace.line("CONTROL-WIRING transport=\(await ssh.usesOpenSSHTransport) knownHosts=\(knownHosts)")

        let service = await MainActor.run { SFTPService() }
        await MainActor.run { service.preferredBackend = .automatic }

        var failure: String?
        do {
            try await withHardDeadline(Self.legTimeout) {
                try await service.connect(using: ssh)
            }
        } catch {
            failure = Tier2Trace.describe(error)
        }

        // `currentPath` is assigned only after the Citadel leg's remote
        // `realPath` round-trip succeeds (SFTPService.swift:162), so a non-empty
        // path means the SFTP subsystem was genuinely reached — not merely that
        // nothing threw.
        let currentPath = await MainActor.run { service.currentPath }
        trace.line("CONTROL-RESULT failure=\(failure ?? "<none>") currentPath=\(currentPath.isEmpty ? "<empty>" : currentPath)")
        trace.line("B02-CONTROL-END")
        trace.flush()

        #expect(
            failure == nil,
            "the unpinned control must reach the filesystem through the Citadel leg; it failed with \(failure ?? "<none>")"
        )
        #expect(
            !currentPath.isEmpty,
            "the control must complete an SFTP round-trip; the remote path is empty, so nothing was reached"
        )

        await service.disconnect()
        await ssh.disconnect()

        #expect(
            bytes(of: Self.appSupportKnownHosts) == appSupportBefore,
            "even the control must not touch the real known_hosts"
        )
    }

    // MARK: - The gate

    /// The contract. Pinned to A, server presents B: the native leg raises the
    /// trust error, it reaches the caller, and the OpenSSH leg never consults
    /// the trust store that has never seen this host.
    @Test("a native host-key mismatch returns the trust error and never opens the fallback")
    func hostKeyMismatchDoesNotReachTheOpenSSHFallback() async throws {
        let trace = Tier2Trace(path: Self.tracePath("gate"), secrets: [BenchSSHServerSmokeTests.password])
        trace.line("B02-BEGIN")

        let server = try await startServer()
        defer { server.stop() }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let knownHosts = dir.appendingPathComponent("known_hosts").path
        try Data().write(to: URL(fileURLWithPath: knownHosts))

        let appSupportBefore = bytes(of: Self.appSupportKnownHosts)
        trace.line("B02-SERVER port=\(server.port) hostKey=B(seed=0x5A)")
        trace.line("APP-SUPPORT-BEFORE bytes=\(appSupportBefore.count)")

        let pinnedA = SSHHostFingerprint(hash: "SHA256:" + String(repeating: "A", count: 43))
        let store = PinnedHostKeyStore(pinned: pinnedA)
        let ssh = try await makeSession(
            store: store, knownHostsOverride: knownHosts, port: server.port
        )

        // Preconditions that make this gate bite. If the compatibility transport
        // were unavailable the fallback could not have been permitted anyway,
        // and the gate would pass without proving anything.
        let transportIsOpenSSH = await ssh.usesOpenSSHTransport
        #expect(
            transportIsOpenSSH,
            "the fallback must be available for the gate to be meaningful; it declined because OpenSSH transport was not active"
        )
        let openSSHLegAvailable = try await ssh.openOpenSSHSFTPClient() != nil
        #expect(
            openSSHLegAvailable,
            "the OpenSSH leg must be constructible, or a permitted fallback could not have succeeded"
        )
        trace.line("PRECONDITIONS transport=\(transportIsOpenSSH) openSSHLegAvailable=\(openSSHLegAvailable) pinned=A")

        let service = await MainActor.run { SFTPService() }
        await MainActor.run { service.preferredBackend = .automatic }

        var outcome = B02Outcome.timedOut
        do {
            try await withHardDeadline(Self.legTimeout) {
                try await service.connect(using: ssh)
            }
            outcome = .connectedUnexpectedly
        } catch {
            if error is B02DeadlineError {
                outcome = .timedOut
            } else if case .hostKeyMismatch? = error as? SSHServiceError {
                outcome = .trustRejected(Tier2Trace.describe(error))
            } else {
                outcome = .otherFailure(Tier2Trace.describe(error))
            }
        }

        let fallbackStore = bytes(of: knownHosts)
        trace.line("")
        trace.line("B02-RESULT outcome=\(outcome.label)")
        trace.line("B02-DETAIL \(outcome.detail)")
        trace.line("B02-FALLBACK-STORE path=\(knownHosts) \(Tier2KnownHosts.describe(String(decoding: fallbackStore, as: UTF8.self)))")
        trace.line("B02-END")
        trace.flush()

        // --- the designated assertion -----------------------------------------
        // The second transport's trust store must be exactly as empty as it was.
        // Under a permitted fallback this file gains an entry for the very key
        // the native leg rejected, which is the whole of AUDIT-FIND-001's
        // mechanism.
        //
        // This assertion is chosen because no timeout can turn it green or red
        // for the wrong reason: the key is written within a second or two of
        // the fallback starting, and if no key was ever written then nothing was
        // persisted and the contract did hold.
        #expect(
            fallbackStore.isEmpty,
            """
            the OpenSSH fallback consulted its own trust store and persisted \
            the key the native leg had just rejected. That is the trust \
            downgrade B-02 exists to prevent. Recorded: \
            \(Tier2KnownHosts.describe(String(decoding: fallbackStore, as: UTF8.self)))
            """
        )

        // --- the rest of the contract -----------------------------------------
        // Connecting at all is the second thing the fallback must never enable.
        #expect(
            outcome != .connectedUnexpectedly,
            "connect(using:) returned normally, so the fallback connected on the strength of a key the native leg rejected"
        )

        // The third step — the caller receives the *native* trust error — is
        // only observable if `connect` returned. It is reported precisely rather
        // than folded into a pass, because a timeout is not a contract violation
        // and asserting otherwise would manufacture a red that proves nothing.
        switch outcome {
        case .trustRejected:
            trace.line("B02-TRUST-ERROR delivered=SSHServiceError.hostKeyMismatch")
            trace.flush()
        case .timedOut:
            // Named, not hidden. This run does NOT verify trust-error delivery:
            // the fallback leg blocked and `connect` never returned. Per the
            // skipped-is-not-executed rule that step is NOT VERIFIED here.
            trace.line("B02-TRUST-ERROR NOT VERIFIED: the fallback leg blocked, so connect never returned")
            trace.flush()
        case let .otherFailure(detail):
            Issue.record(
                "the caller must receive the native leg's own SSHServiceError.hostKeyMismatch; got \(detail)"
            )
        case .connectedUnexpectedly:
            break // already reported above
        }

        let entries = await MainActor.run { service.entries }
        #expect(
            entries.isEmpty,
            "no directory listing may come from a rejected host key; got \(entries.count) entries"
        )

        #expect(
            bytes(of: Self.appSupportKnownHosts) == appSupportBefore,
            "the real known_hosts must be untouched regardless of what the fallback did"
        )

        await service.disconnect()
        await ssh.disconnect()
    }
}

// MARK: - Outcome

/// What `SFTPService.connect(using:)` actually did.
///
/// `timedOut` is deliberately its own case. A gate whose verdict could be
/// produced by a hung run is not a gate, so the deadline must be visible in the
/// result rather than folded into a pass.
enum B02Outcome: Equatable {
    case trustRejected(String)
    case otherFailure(String)
    case connectedUnexpectedly
    case timedOut

    var label: String {
        switch self {
        case .trustRejected: "trustRejected"
        case .otherFailure: "otherFailure"
        case .connectedUnexpectedly: "connectedUnexpectedly"
        case .timedOut: "timedOut"
        }
    }

    var detail: String {
        switch self {
        case let .trustRejected(detail), let .otherFailure(detail): detail
        case .connectedUnexpectedly: "connect(using:) returned normally — the fallback ran and succeeded"
        case .timedOut: "no outcome within the leg deadline"
        }
    }
}

// MARK: - Hard deadline

struct B02DeadlineError: Error {}

/// A deadline that actually bounds the *test*, not just the returned value.
///
/// `SSHNetworkService.withThrowingTimeout` — the obvious thing to reach for —
/// does not. It uses `withThrowingTaskGroup`, whose body cannot return until
/// every child task has finished, so cancelling the loser does not release the
/// caller: the winner may time out and be reported, while the run itself stays
/// wedged behind a child blocked in a pipe read that ignores cancellation. A
/// mutation run using it hung for the whole session.
///
/// So the worker is an unstructured `Task` whose result arrives through a box,
/// and the caller returns on the deadline regardless. `cancel()` is best-effort
/// — the abandoned worker may outlive the test, and
/// `SSHNetworkService.disconnect()` is what actually kills the child process.
func withHardDeadline<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = B02ResultBox<T>()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)

    let worker = Task {
        do { box.set(.success(try await operation())) }
        catch { box.set(.failure(error)) }
    }

    while box.result == nil, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    worker.cancel()

    guard let result = box.result else { throw B02DeadlineError() }
    return try result.get()
}

/// Minimal handoff between the worker task and the waiting caller.
final class B02ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    func set(_ value: Result<T, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var result: Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}