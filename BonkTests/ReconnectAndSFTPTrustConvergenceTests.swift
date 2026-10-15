import Foundation
import Testing
import Citadel
@testable import Bonk

/// AUDIT-FIND-001 — the reconnect and SFTP paths must resolve trust too.
///
/// ## Why these two
///
/// The first connect was gated, the per-hop argv was gated, and the probe was
/// gated. Two paths still reached `ssh` unobserved:
///
///  - **reconnect** — `performSingleReconnect` builds a *new* backend rather than
///    reusing the stored one, so it re-resolves trust from scratch on every
///    attempt. That is correct behaviour and it is exactly the kind of copy that
///    drifts: it used to call `OpenSSHKnownHostsResolver.production()` directly,
///    while the connect path honoured an override. Two sites, two trust
///    decisions.
///  - **SFTP** — `runSFTP` has its own argv builder, separate from `sshArguments`,
///    so `StrictHostKeyChecking` and `UserKnownHostsFile` are spelled out again
///    there rather than inherited.
///
/// ## What is asserted
///
/// The user-supplied rule for these gates is that they must verify the argv and
/// the trust-file *contents*, not merely that the operation rejected or
/// succeeded. That is a direct consequence of AUDIT-DEF-001: a deleted trust file
/// and a substituted key both make the operation fail, so "it failed" is not
/// evidence. These gates read the path production handed to the binary, require
/// the file to exist, and require it to carry the canonical key for that host.
///
/// A third responsibility, carried over from the per-hop gate and kept
/// deliberately: verify the canonical store is unchanged afterwards. A path that
/// resolved by first-contact probe instead of by pin would show up as a new
/// record.
@Suite("AUDIT-FIND-001 — reconnect and SFTP resolve trust like first connect")
struct ReconnectAndSFTPTrustConvergenceTests {
    // MARK: - Reconnect

    @Test("the reconnect path resolves trust through the canonical store, not by re-probing")
    func reconnectResolvesTrustBeforeSpawning() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0x3C,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { server.stop() }

        let dir = try HostKeyFixtureSupport.makeTempDir("reconnect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        let pinned = try HostKeyFixtureSupport.scannedKey(port: UInt16(server.port))
        #expect(try store.recordIfAbsentOrMatching(
            host: "127.0.0.1", port: UInt16(server.port), candidate: pinned
        ) != .persistenceFailure, "seeding the canonical store failed")

        let recorder = RecordingOpenSSHProcessSpawner(recordOnly: true)
        let service = SSHNetworkService(hostKeyStore: PinnedHostKeyStore(pinned: pinned.fingerprint))
        await service.setVNextPreferredBackend(.compatibility)
        await service.setOpenSSHKnownHostsResolverOverride(OpenSSHKnownHostsResolver(store: store))
        await service.setOpenSSHProcessSpawnerOverride(recorder)
        let before = (try? Data(contentsOf: dir.appendingPathComponent("records.json"))) ?? Data()
        _ = await reconnectWithPTY(service: service, config: config(port: server.port))

        let invocation = try #require(
            recorder.connectionInvocation(port: server.port),
            """
            the reconnect path launched no /usr/bin/ssh, so it established no trust \
            decision at all. captured: \(recorder.recorded.map { $0.executable })
            """
        )

        try OpenSSHTrustFileAssertions.expectStrictTrustFile(
            invocation.arguments,
            carrying: pinned,
            host: "127.0.0.1",
            port: server.port,
            labelled: "reconnect"
        )

        // Trust state must be identical: a reconnect verifies, it does not learn.
        let after = (try? Data(contentsOf: dir.appendingPathComponent("records.json"))) ?? Data()
        #expect(after == before,
                """
                the reconnect path wrote to the canonical store. Reconnect resolves \
                trust; it must not establish new trust, or a substituted key could be \
                learned during recovery rather than refused.
                """)
    }

    // MARK: - SFTP

    @Test("the SFTP argv carries a strict trust file holding the canonical key")
    func sftpResolvesTrustBeforeSpawning() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0x4D,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { server.stop() }

        let dir = try HostKeyFixtureSupport.makeTempDir("sftp-trust")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CanonicalHostKeyStore(fileURL: dir.appendingPathComponent("records.json"))
        let pinned = try HostKeyFixtureSupport.scannedKey(port: UInt16(server.port))
        #expect(try store.recordIfAbsentOrMatching(
            host: "127.0.0.1", port: UInt16(server.port), candidate: pinned
        ) != .persistenceFailure, "seeding the canonical store failed")

        let recorder = RecordingOpenSSHProcessSpawner(recordOnly: true)
        let backend = try OpenSSHBackend(
            config: config(port: server.port),
            spawner: recorder,
            knownHostsResolver: OpenSSHKnownHostsResolver(store: store)
        )
        defer { backend.close() }

        // The recorder's process exits immediately, so this returns at the
        // readiness check rather than after the 120s SFTP prompt deadline.
        _ = try? await backend.runSFTP(commands: ["pwd"])

        let invocation = try #require(
            recorder.sftpInvocation(port: server.port),
            "no /usr/bin/sftp launch recorded; captured: \(recorder.recorded.map { $0.executable })"
        )

        // SFTP is not the PTY argv builder, so its trust policy is spelled out
        // separately in production and has to be checked separately here.
        #expect(
            invocation.arguments.contains { $0.contains("StrictHostKeyChecking=yes") },
            """
            the SFTP connection must verify the host key strictly. Its argv is built \
            independently of the PTY path, so it does not inherit that policy. \
            argv: \(invocation.arguments)
            """
        )

        try OpenSSHTrustFileAssertions.expectStrictTrustFile(
            invocation.arguments,
            carrying: pinned,
            host: "127.0.0.1",
            port: server.port,
            labelled: "sftp"
        )

        #expect(try store.lookup(host: "127.0.0.1", port: UInt16(server.port)).record?.fingerprint == pinned.fingerprint,
                "the SFTP path changed the canonical pin")
    }

    // MARK: - Helpers

    /// Drives one reconnect attempt with a PTY configured.
    ///
    /// A PTY config is required, not optional: with `lastPTYConfig` nil the
    /// reconnect path takes the "no PTY" branch, confirms the transport and
    /// returns without ever calling `openPTY` — so it resolves no trust file and
    /// launches nothing. The first version of this gate omitted the PTY and
    /// failed on an empty recording, which reads like a production bug but was
    /// actually a fixture that never reached the code under test.
    private func reconnectWithPTY(
        service: SSHNetworkService,
        config: SSHConnectionConfig
    ) async -> Bool {
        await service.prepareForReconnectTest(
            config: config,
            ptyConfig: SSHNetworkService.PTYConfig(cols: 80, rows: 24, termType: "xterm-256color")
        )
        return await service.performSingleReconnect()
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

// MARK: - Shared trust-file assertions

/// Assertions about the trust file a connection was actually given.
///
/// Extracted because four gates now need the same properties, and because the
/// middle one is the one that keeps getting forgotten: a path can be named in
/// argv without any file existing at it, and AUDIT-DEF-001 was exactly that.
enum OpenSSHTrustFileAssertions {
    /// Require a trust file to exist and to carry the key it is meant to carry.
    ///
    /// Existence and contents are asserted separately because the two failures
    /// mean different things: the first means `ssh` was given nothing to verify
    /// against, the second means it was given the wrong thing.
    static func expectTrustFile(
        _ path: String, carries record: HostKeyRecord, labelled label: String
    ) throws {
        #expect(
            FileManager.default.fileExists(atPath: path),
            """
            the \(label) hop's trust file does not exist at \(path). A missing trust \
            file and a substituted key both make ssh refuse with "Host key \
            verification failed.", so this must be checked before any gate that \
            relies on the refusal.
            """
        )
        guard FileManager.default.fileExists(atPath: path) else { return }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let carriesKey = contents.contains(record.keyBlob.base64EncodedString())
        #expect(
            carriesKey,
            """
            the \(label) hop's trust file does not carry \(record.fingerprint.hash). \
            Two hosts sharing one trust file would still pass a "paths differ" \
            check while being verified against each other's pins. \
            \(Self.describe(contents, carriesKey: carriesKey))
            """
        )
    }

    /// Describe trust-file contents without printing them.
    ///
    /// An earlier version embedded `<\(contents)>` in the failure message, and a
    /// mutation run duly printed the user's real `known_hosts` — their actual
    /// host list — into the test log. A security gate that leaks trust material
    /// when it fails is a gate whose output must be scrubbed before it is shared,
    /// which defeats the purpose of having it. Size and shape are enough to
    /// diagnose the failure.
    private static func describe(_ contents: String, carriesKey: Bool) -> String {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        return """
        file holds \(lines.count) line(s), \(contents.count) byte(s); \
        contains the expected key: \(carriesKey). \
        Contents withheld — they are real trust state, not fixture text.
        """
    }
    /// Require the argv to name a trust file that exists, carries `record`, and is
    /// verified strictly.
    ///
    /// `record` rather than a fingerprint alone: two hosts could in principle
    /// present the same key, and the property under test is that *this host's*
    /// pin reached the binary, not that some key did.
    static func expectStrictTrustFile(
        _ arguments: [String],
        carrying record: HostKeyRecord,
        host: String,
        port: Int,
        labelled label: String
    ) throws {
        #expect(
            arguments.contains { $0.contains("StrictHostKeyChecking=yes") },
            "\(label): StrictHostKeyChecking=yes missing; argv: \(arguments)"
        )
        #expect(
            !arguments.contains { $0.contains("StrictHostKeyChecking=accept-new") },
            "AUDIT-FIND-001: \(label) argv accepts unknown keys; argv: \(arguments)"
        )

        let path = try #require(
            knownHostsPath(in: arguments),
            "\(label): no UserKnownHostsFile in argv: \(arguments)"
        )

        #expect(
            FileManager.default.fileExists(atPath: path),
            """
            \(label): ssh was pointed at a trust file that does not exist. With strict \
            checking this fails closed with the same message a substituted key \
            produces, so any gate that only checks the outcome would pass for the \
            wrong reason. path: \(path)
            """
        )
        guard FileManager.default.fileExists(atPath: path) else { return }

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!contents.isEmpty, "\(label): the trust file at \(path) is empty")
        let carriesKey = contents.contains(record.keyBlob.base64EncodedString())
        #expect(
            carriesKey,
            """
            \(label): the trust file does not carry \(record.fingerprint.hash) for \
            \(host):\(port). \(Self.describe(contents, carriesKey: carriesKey))
            """
        )
    }

    /// Pull `UserKnownHostsFile` out of a flat argv or a quoted `ProxyCommand`.
    ///
    /// Quote-aware, and that is not incidental. Production wraps the path in
    /// `sshConfigQuote`, and a trust file under Application Support contains a
    /// space ("Application Support"). An earlier version split on spaces and
    /// returned `"/Users/…/Library/Application` — a truncated path, which then
    /// failed the existence check for the wrong reason. The mutation run that
    /// exposed it reported a missing file rather than "this argv points at the
    /// legacy trust file", which is the defect actually under test.
    ///
    /// A gate whose failure message is wrong is a gate that will eventually be
    /// believed when it should be doubted.
    static func knownHostsPath(in arguments: [String]) -> String? {
        for argument in arguments {
            for piece in quoteAwareSplit(argument) {
                guard piece.hasPrefix("UserKnownHostsFile=") else { continue }
                let value = String(piece.dropFirst("UserKnownHostsFile=".count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Split on spaces, but keep quoted runs intact and strip the quotes.
    ///
    /// Deliberately minimal: enough to recover an `-o Key=Value` argument from a
    /// `ProxyCommand` string, and not a general shell parser.
    static func quoteAwareSplit(_ argument: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quote: Character?
        for character in argument {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { pieces.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

extension RecordingOpenSSHProcessSpawner {
    /// The SFTP launch, identified the same way as the ssh one.
    func sftpInvocation(port: Int) -> Invocation? {
        recorded.first {
            $0.executable == "/usr/bin/sftp"
                && $0.arguments.contains("-P")
                && $0.arguments.contains(String(port))
        }
    }
}