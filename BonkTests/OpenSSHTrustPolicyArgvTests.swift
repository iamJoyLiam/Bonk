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

    var recorded: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    private let wrapped: any OpenSSHProcessSpawning = DefaultOpenSSHProcessSpawner()

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
        return try wrapped.spawn(
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

        let recorder = RecordingOpenSSHProcessSpawner()
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
        let backend = try OpenSSHBackend(config: config, spawner: recorder)

        // The launch happens inside openPTY, before any handshake outcome. A
        // connection that later fails still tells us what argv was used, so the
        // failure is deliberately swallowed.
        _ = try? backend.openPTY(cols: 80, rows: 24, termType: "xterm-256color", onExit: {})

        let invocation = try #require(
            recorder.connectionInvocation(port: server.port),
            """
            no /usr/bin/ssh connection launch for port \(server.port) was \
            recorded; captured: \(recorder.recorded.map { $0.executable })
            """
        )
        let arguments = invocation.arguments

        #expect(
            arguments.contains { $0 == "StrictHostKeyChecking=accept-new" },
            "the connection must carry the current host-key policy; argv: \(arguments)"
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
}
