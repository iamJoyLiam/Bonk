import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import Bonk

/// Does the pooled `sftp` process actually remove a connection per folder?
///
/// ## The claim under test
///
/// `OpenSSHSFTPClient.listDirectory` issued one `ls -l`, and `runSFTP` spawned a
/// fresh `sftp` process for it — so every folder the user opened cost a full
/// TCP + KEX + host-key + auth cycle. The pooled session should make all but the
/// first of those free.
///
/// ## How it is measured
///
/// By counting *spawns*, not by wall clock. A timing comparison against a local
/// fixture is meaningless — localhost handshakes cost microseconds, which is
/// exactly why the regression survived unnoticed in the first place. Counting the
/// processes that were actually launched is the quantity that changed, and it is
/// the one a remote user feels.
@Suite("SFTP — one sftp process serves many directory listings")
struct SFTPPooledSessionTests {
    /// A spawner that records what it was asked to launch.
    private final class CountingSpawner: OpenSSHProcessSpawning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sftpSpawns = 0
        private(set) var sshSpawns = 0
        let wrapped: any OpenSSHProcessSpawning = DefaultOpenSSHProcessSpawner()

        func spawn(
            executable: String, arguments: [String], cols: Int,
            rows: Int, termType: String, environment: [String: String]
        ) throws -> OpenSSHProcessTransport {
            lock.lock()
            if executable.hasSuffix("sftp") { sftpSpawns += 1 } else { sshSpawns += 1 }
            lock.unlock()
            return try wrapped.spawn(
                executable: executable, arguments: arguments,
                cols: cols, rows: rows, termType: termType, environment: environment
            )
        }

        var spawns: Int { lock.withLock { sftpSpawns } }
    }

    @Test("repeated directory listings spawn at most one sftp process")
    func repeatedListingsReuseOneProcess() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0xA7,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { server.stop() }

        let dir = try HostKeyFixtureSupport.makeTempDir("sftp-pool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        let scanned = try HostKeyFixtureSupport.scannedKey(port: UInt16(server.port))
        _ = try store.recordIfAbsentOrMatching(
            host: "127.0.0.1", port: UInt16(server.port), candidate: scanned
        )

        let spawnCounter = CountingSpawner()
        let backend = try OpenSSHBackend(
            config: SSHConnectionConfig(
                host: "127.0.0.1",
                port: UInt16(server.port),
                username: "bench",
                authMethod: .password(BenchSSHServerSmokeTests.password),
                bypassControlMaster: true
            ),
            spawner: spawnCounter,
            knownHostsResolver: OpenSSHKnownHostsResolver(store: store)
        )
        defer { backend.close() }

        // Ten listings of the same directory, driven through the **client** —
        // not through `backend.runSFTPControlCommands` directly.
        //
        // An earlier version of this test called the backend method and stayed
        // green when the routing decision in `OpenSSHSFTPClient.runControl` was
        // reverted to per-command spawning. The gate was watching a layer the
        // product does not use. The decision that matters is made in the client,
        // so the gate has to go through the client.
        let client = backend.makeSFTPClient()
        // Bounded, because the failure mode being guarded against is *slowness*.
        //
        // Without pooling, each listing spawns its own `sftp` and each of those
        // can spend up to the 120s readiness deadline, so ten of them do not merely
        // fail the spawn count — they wedge the run. A gate that hangs under
        // mutation is a gate that gets deleted rather than trusted, so the budget
        // turns "hangs forever" into a named failure.
        let budget = Duration.seconds(90)
        let counter = ListingCounter()
        let finished = CompletionBox()
        // A detached worker, not a task group.
        //
        // `withThrowingTaskGroup` cannot return while a stuck child is still
        // running, so racing the loop against a sleeping sibling does not bound
        // anything — the group waits for the loser. That is the defect already
        // recorded against `withThrowingTimeout` in this repo, and the first two
        // versions of this gate reproduced it by copying the pattern. The
        // deadline has to be observed by the *caller*, so the work is detached and
        // polled.
        Task.detached {
            defer { finished.complete() }
            for _ in 0 ..< 10 {
                if Task.isCancelled { return }
                // Only the call succeeding is asserted, not that it parsed into
                // entries. `parseListingLine` requires the mode to start with
                // one of `-dlcbps`, and the bench fixture answers `?rwxr-xr-x` —
                // a pre-existing fixture artifact with nothing to do with pooling.
                // Gating on parsed rows would make this test fail for a reason
                // unrelated to the property it protects.
                guard (try? await client.listDirectory(at: ".")) != nil else { return }
                counter.increment()
            }
        }

        let deadline = ContinuousClock.now + budget
        while !finished.isComplete, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let completed = finished.isComplete
        let listings = counter.value
        // Assertions happen here, in the test body, never inside the detached
        // task: a `#expect` fired from a worker that outlives the test writes into
        // a torn-down harness, which surfaces as an ABI crash instead of a named
        // failure.
        #expect(
            completed,
            """
            ten directory listings did not finish in time. Without a pooled process \
            each one pays a full SSH connection, which is exactly the regression this \
            gate catches. Completed \(listings) of 10.
            """
        )
        #expect(listings == 10, "expected 10 successful listings, got \(listings)")

        #expect(listings == 10)
        // The whole point: one process for ten listings, not ten processes.
        // Before pooling this was 10. Allow exactly one, not "at most a few" —
        // a sloppy bound would hide a regression to per-command spawning.
        #expect(
            spawnCounter.spawns == 1,
            """
            \(listings) directory listings launched \(spawnCounter.spawns) sftp processes. \
            Control commands must share one pooled process; a value above 1 means \
            pooling is not in effect and every folder click costs a connection again.
            """
        )
    }

    /// A transfer must not be parked on the shared process.
    ///
    /// If `get`/`put` were routed through the pool, a multi-minute transfer would
    /// block every other operation behind it and cancellation would have no child
    /// to kill.
    @Test("a transfer command is never served from the pool")
    func transfersAreNotPooled() async throws {
        let dir = try HostKeyFixtureSupport.makeTempDir("sftp-pool-2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))

        let spawnCounter = CountingSpawner()
        let backend = try OpenSSHBackend(
            config: SSHConnectionConfig(
                host: "127.0.0.1", port: 65001, username: "bench",
                authMethod: .password("x"), bypassControlMaster: true
            ),
            spawner: spawnCounter,
            knownHostsResolver: OpenSSHKnownHostsResolver(store: store)
        )
        defer { backend.close() }

        // Unreachable host: the command fails, but the routing decision is what is
        // under test, and routing is decided before any connection is attempted.
        do {
            _ = try await backend.runSFTPControlCommands(["get /tmp/a /tmp/b"])
        } catch {
            // Expected: nothing is listening. The spawn count is the evidence.
        }

        #expect(
            spawnCounter.spawns == 0,
            """
            a `get` reached the pooled control path and launched a shared sftp \
            process. Transfers need their own process so a long transfer does not \
            block the pool and so cancellation has a child to kill.
            """
        )
    }
}
enum SFTPPoolFixtureError: Error { case budgetExceeded }

/// Thread-safe tally: the listing loop runs in a detached task group child.
private final class ListingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Completion flag the caller polls. Separate from `ListingCounter` because a
/// detached worker can fail part-way and still need to release the deadline.
private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isComplete: Bool { lock.withLock { done } }
    func complete() { lock.withLock { done = true } }
}
