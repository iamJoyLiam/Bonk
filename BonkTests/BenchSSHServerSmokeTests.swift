import Foundation
import Testing
import NIOCore
import NIOPosix
@testable import Bonk

/// Validates `BenchSSHServer` itself, before any finding depends on it.
///
/// This is a harness test, not evidence for AUDIT-FIND-001 or B-02. It exists
/// because both of those need a real `/usr/bin/ssh` making a real host-key
/// decision against a real server, and a fixture that silently got the trust
/// semantics wrong would be indistinguishable from a trust finding.
///
/// Isolation is deliberate and total, so what is under test is OpenSSH plus the
/// fixture and not the developer machine:
///   `-F /dev/null`                       ignore ~/.ssh/config entirely
///   `UserKnownHostsFile`                 a temp file this test owns
///   `GlobalKnownHostsFile=/dev/null`     no system-wide trust
///   `SSH_ASKPASS`                        password supplied without a tty
@Suite("Bench SSH server — fixture smoke test")
struct BenchSSHServerSmokeTests {
    static let password = "bench-fixture-password"

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// A password helper, because `ssh` reads the passphrase from a terminal we
    /// do not own. Same technique the key generator uses, for the same reason:
    /// the secret must not reach argv.
    private func makeAskpass(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("askpass")
        let script = "#!/bin/sh\nexec cat '\(dir.appendingPathComponent("pw").path)'\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try Data((Self.password + "\n").utf8).write(to: dir.appendingPathComponent("pw"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("pw").path)
        return url
    }

    struct Outcome {
        var status: Int32
        var stderr: String
        var stdout: String
    }

    private func connect(
        port: Int, knownHosts: URL, askpass: URL
    ) throws -> Outcome {
        let out = Pipe()
        let err = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "PreferredAuthentications=password",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=10",
            "-p", String(port),
            "bench@127.0.0.1", "true",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        proc.environment = environment
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Outcome(
            status: proc.terminationStatus,
            stderr: String(decoding: errData, as: UTF8.self),
            stdout: String(decoding: outData, as: UTF8.self)
        )
    }

    /// The fixture must exhibit exactly the two host-key behaviours the
    /// OpenSSH backend relies on, or AUDIT-FIND-001's gate is measuring the
    /// fixture instead of the product.
    @Test("accept-new takes an unseen key, then rejects that host's key changing")
    func acceptNewTakesUnknownThenRejectsChanged() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let knownHosts = dir.appendingPathComponent("known_hosts")
        try Data().write(to: knownHosts)
        let askpass = try makeAskpass(in: dir)

        guard let firstPort = SSHFixturePort.claim(in: BenchSSHServer.ports) else {
            Issue.record("no free port")
            return
        }
        let port = Int(firstPort)

        // Phase A — an unknown key must be accepted and recorded.
        let serverA = try await BenchSSHServer.start(
            hostKeySeed: 0x5A, password: Self.password, port: port,
            execDelegate: SubprocessExecDelegate(spawned: SpawnedProcesses())
        )
        let first = try connect(port: port, knownHosts: knownHosts, askpass: askpass)
        serverA.stop()

        #expect(first.status == 0,
                "an unseen key must be accepted under accept-new; stderr: \(first.stderr)")
        let recorded = try String(contentsOf: knownHosts, encoding: .utf8)
        #expect(!recorded.isEmpty, "the accepted key must be written to known_hosts")

        // Phase B — the same host:port now presenting a different key must be
        // rejected. Same port, same trust file; only the key changes.
        let serverB = try await BenchSSHServer.start(
            hostKeySeed: 0x7C, password: Self.password, port: port,
            execDelegate: SubprocessExecDelegate(spawned: SpawnedProcesses())
        )
        defer { serverB.stop() }
        let second = try connect(port: port, knownHosts: knownHosts, askpass: askpass)

        #expect(second.status != 0,
                "a changed key must be rejected under accept-new; it was accepted")
        #expect(
            second.stderr.lowercased().contains("host key") || second.stderr.lowercased().contains("hostkey"),
            "rejection must be reported as a host-key failure; stderr: \(second.stderr)"
        )
    }
}
