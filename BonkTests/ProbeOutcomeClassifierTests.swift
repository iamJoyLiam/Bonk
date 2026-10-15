import Foundation
import Testing
import NIOCore
import NIOPosix
import Citadel
@testable import Bonk

/// `ProbeOutcome` and `ProbeOutcomeClassifier` live in
/// `Bonk/Services/SSH/ProbeOutcomeClassifier.swift`, not here.
///
/// This file used to define its own copy so the classifier could be exercised
/// before the production probe existed. Now that `HostKeyProbe` calls the
/// production classifier, a second copy would be the failure mode this audit
/// keeps finding: a helper that proves the right thing while production does
/// something else. The tests below drive the same function production runs.
///
/// Five real OpenSSH outcomes are observed against a live `BenchSSHServer`:
/// mismatched key, verified key with auth refused, refused connection, stalled
/// KEX, and `accept-new` auth refusal with no verification — the last being the
/// case a `Permission denied` check would wrongly call "accepted".
@Suite("AUDIT-FIND-001 probe outcome — observation pass")
struct ProbeOutcomeObservationTests {
    private static let ports: ClosedRange<UInt16> = 25_400 ... 25_479
    private static let probeTimeout = 20
    private static let tracePath =
        "/tmp/bonk-probe-outcome-trace-\(ProcessInfo.processInfo.processIdentifier).txt"

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    struct ProbeRun {
        var status: Int32
        var stdout: String
        var stderr: String
        var elapsed: TimeInterval
        var timedOut: Bool
    }

    /// The exact credential-free flag set from the remediation design.
    /// `LC_ALL=C` reduces locale-dependent diagnostic text, and `-F /dev/null`
    /// keeps the user's own ssh config out of the result.
    private func probe(
        host: String,
        port: UInt16,
        knownHosts: String,
        hostKeyAlgorithms: String,
        strictHostKeyChecking: String = "yes"
    ) -> ProbeRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-v",
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=\(strictHostKeyChecking)",
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlgorithms=\(hostKeyAlgorithms)",
            "-o", "PreferredAuthentications=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "BatchMode=yes",
            // These three are not interchangeable with the flags above, and the
            // difference is observable in the log: with only the method flags,
            // ssh still *loaded* ~/.ssh/id_ed25519 (it never offered it, but the
            // identity material was read). `PreferredAuthentications=none`
            // forbids choosing a method; `IdentityFile=none` stops default
            // identity files being loaded at all; `IdentityAgent=none` closes the
            // agent path. Literal `none`, not an empty value — OpenSSH documents
            // `none` as the sentinel for both.
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityFile=none",
            "-o", "IdentityAgent=none",
            "-o", "ConnectTimeout=\(Self.probeTimeout)",
            "-p", String(port),
            "probe@\(host)", "true",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let start = Date()
        var timedOut = false
        do {
            try process.run()
        } catch {
            return ProbeRun(
                status: -1, stdout: "", stderr: "launch failed: \(error)",
                elapsed: 0, timedOut: false
            )
        }

        // Bounded wait, unlike a bare readDataToEndOfFile: a wedged probe must
        // not hang the suite.
        let deadline = start.addingTimeInterval(Double(Self.probeTimeout) + 10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            _ = process.waitUntilExit()
        }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProbeRun(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            elapsed: Date().timeIntervalSince(start),
            timedOut: timedOut
        )
    }

    private func scan(port: UInt16) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", "10", "-t", "ed25519", "-p", String(port), "127.0.0.1"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // ssh-keyscan echoes the listener's banner as a `#`-prefixed comment, and
        // it does so on the same connection it scans. Taking the first line picks
        // up `SSH-2.0-SwiftNIOSSH_1.0 [127.0.0.1]:PORT` rather than a key, which
        // silently turns every key assertion into a comparison of banners.
        let keyLine = String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
                return trimmed.split(separator: " ").map(String.init).count >= 3
            }
        return try #require(keyLine, "ssh-keyscan returned no key line for the live fixture")
    }

    /// Flip characters in the *key material* of a base64 blob, keeping the key
/// structurally valid.
///
/// Two earlier attempts got this wrong, and both produced a scenario that tested
/// the wrong layer:
///
///   - rewriting the whole blob to a repeated character yielded something ssh
///     refused to parse at all
///   - mutating early characters corrupted the embedded `ssh-ed25519` type
///     string, so ssh logged `parse error in hostkeys file` and then
///     `No ED25519 host key is known ... strict checking`
///
/// That second case is important: it *ends* in `Host key verification failed`,
/// the same final line as a genuine mismatch, but for the wrong reason. A
/// classifier keyed on that line alone would pass a corrupt trust file as a
/// correctly-rejected key. The structural prefix occupies the first 48 base64
/// characters (4-byte length, 11-byte type string, 4-byte key length), so
/// mutation starts past it and the result decodes to a real 32-byte ed25519 key.
private func mutateKeyMaterial(_ blob: String) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var characters = Array(blob)
        // 48 chars covers the structural prefix for ed25519; the 32-byte key body
        // is ~44 more, so indices 48..<54 are safely inside the key.
        let structuralPrefix = 48
        guard characters.count > structuralPrefix + 6 else { return blob }
        for index in structuralPrefix ..< (structuralPrefix + 6) {
            guard let position = alphabet.firstIndex(of: characters[index]) else { continue }
            characters[index] = alphabet[(position + 7) % alphabet.count]
        }
        return String(characters)
    }

    private func startServer() async throws -> BenchSSHServer.Instance {
        try await BenchSSHServer.start(
            hostKeySeed: 0x41,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
    }

    /// A listener that accepts TCP and then says nothing, so KEX never completes.
    ///
    /// Needed to prove the probe's deadline can actually kill a wedged attempt.
    /// A refused connection proves nothing about that: it returns immediately.
    enum StallSSHServer {
        final class Instance {
            let port: UInt16
            private var listener: (any Channel)?
            private let group: MultiThreadedEventLoopGroup

            init(port: UInt16, listener: any Channel, group: MultiThreadedEventLoopGroup) {
                self.port = port
                self.listener = listener
                self.group = group
            }

            /// Accept, then hold the channel open without writing a banner.
            func stop() {
                let listener = listener
                let group = group
                self.listener = nil
                let held = listener.map(UncheckedSendable.init)
                Task {
                    // Same shape as `BenchSSHServer.Instance.stop()`: hand
                    // ownership to a detached Task through `UncheckedSendable`
                    // rather than awaiting `close()` across the isolation
                    // boundary.
                    if let channel = held?.value {
                        try? await channel.close()
                    }
                    try? await group.shutdownGracefully()
                }
            }
        }

        static func start() async throws -> Instance {
            guard let requested = SSHFixturePort.claim(in: ProbeOutcomeObservationTests.ports) else {
                throw ProbeStallError.noFreePort
            }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            do {
                let listener = try await ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.backlog, value: 8)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        // Deliberately silent: no banner, no KEXINIT.
                        channel.pipeline.addHandler(StallHandler())
                        return channel.pipeline.addHandlers()
                    }
                    .bind(host: "127.0.0.1", port: Int(requested))
                    .wait()
                return Instance(port: requested, listener: listener, group: group)
            } catch {
                try? await group.shutdownGracefully()
                throw error
            }
        }
    }

    enum ProbeStallError: Error { case noFreePort }

    /// Holds the channel and never answers.
    final class StallHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
        func channelInactive(context: ChannelHandlerContext) {}
        func errorCaught(context: ChannelHandlerContext, error: Error) {}
    }

    @Test("observe the three probe outcomes through the production probe")
    func observeThreeOutcomes() async throws {
        let trace = Tier2Trace(path: Self.tracePath, secrets: [BenchSSHServerSmokeTests.password])
        trace.line("PROBE-BEGIN via=HostKeyProbe")
        defer { trace.flush() }

        let server = try await startServer()
        defer { server.stop() }
        let port = server.port

        // The key the fixture really serves. Used to build the candidate records
        // the production probe is handed — the probe writes whatever record it is
        // given into its own trust file, so the record is the thing under test.
        let scanned = try scan(port: UInt16(port))
        let fields = scanned.split(separator: " ").map(String.init)
        let keyType = fields[1]
        let rightBlob = fields[2]
        let wrongBlob = mutateKeyMaterial(rightBlob)
        try #require(wrongBlob != rightBlob, "the wrong key must actually differ")

        let rightRecord = try Self.record(keyType: keyType, blob: rightBlob)
        let wrongRecord = try Self.record(keyType: keyType, blob: wrongBlob)
        trace.line("SCAN keyType=\(keyType) right=\(rightRecord.fingerprint.hash) wrong=\(wrongRecord.fingerprint.hash)")

        let probe = HostKeyProbe()

        // --- scenario 1: the trust file holds a DIFFERENT key ---
        let outcomeWrong = await probe.probe(host: "127.0.0.1", port: UInt16(port), candidate: wrongRecord)
        trace.line("SCENARIO-1 expect=keyRejected actual=\(outcomeWrong.rawValue)")

        // --- scenario 2: the trust file holds the CORRECT key ---
        let outcomeRight = await probe.probe(host: "127.0.0.1", port: UInt16(port), candidate: rightRecord)
        trace.line("SCENARIO-2 expect=keyAcceptedAuthenticationRefused actual=\(outcomeRight.rawValue)")

        // --- scenario 3: nothing listening ---
        // No server on this port, so the probe never reaches a host-key decision.
        let closedPort = SSHFixturePort.claim(in: Self.ports) ?? 25_479
        let outcomeClosed = await probe.probe(
            host: "127.0.0.1", port: closedPort, candidate: rightRecord, timeout: .seconds(20)
        )
        trace.line("SCENARIO-3 expect=inconclusive actual=\(outcomeClosed.rawValue) port=\(closedPort)")

        // --- scenario 4: a listener that accepts and never speaks ---
        let stall = try await StallSSHServer.start()
        defer { stall.stop() }
        let outcomeStall = await probe.probe(
            host: "127.0.0.1", port: stall.port, candidate: rightRecord, timeout: .seconds(3)
        )
        trace.line("SCENARIO-4 expect=inconclusive(timeout) actual=\(outcomeStall.rawValue)")

        trace.line("")
        trace.line("CLASSIFICATIONS")
        for (label, outcome) in [
            ("wrong key", outcomeWrong),
            ("right key", outcomeRight),
            ("refused", outcomeClosed),
            ("stalled", outcomeStall),
        ] {
            trace.line("  \(label) -> \(outcome.rawValue)")
        }
        trace.line("PROBE-END")
        trace.flush()

        // --- assertions ---
        #expect(outcomeWrong == .keyRejected,
                "a trust file holding a different key must classify as keyRejected; got \(outcomeWrong)")
        #expect(outcomeRight == .keyAcceptedAuthenticationRefused,
                """
                the only outcome that may authorise a trust write. The production probe \
                verified the key and was then refused authentication, because it \
                offers no credential. got \(outcomeRight)
                """)
        #expect(outcomeClosed == .inconclusive,
                "a refused connection proves nothing about the host key; got \(outcomeClosed)")
        #expect(outcomeStall == .inconclusive,
                "a stalled KEX must be terminated by the deadline as inconclusive; got \(outcomeStall)")
    }

    /// Build a `HostKeyRecord` from a known_hosts key type and base64 blob.
    private static func record(keyType: String, blob: String) throws -> HostKeyRecord {
        let data = try #require(Data(base64Encoded: blob), "key blob is not base64")
        let parsed = try #require(HostKeyBlob.parse(data), "key blob does not parse")
        #expect(parsed.keyType == keyType, "parsed key type \(parsed.keyType) != scanned \(keyType)")
        return HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: data,
            capability: .nativeAndOpenSSH
        )
    }
}