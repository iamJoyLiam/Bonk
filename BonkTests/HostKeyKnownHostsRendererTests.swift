import Foundation
import Testing
@testable import Bonk

/// Step 4, first increment: rendering canonical records into `known_hosts`
/// content.
///
/// The renderer is where the canonical store becomes something ssh can consume,
/// so every property the security argument rests on is verified here against the
/// real format — most importantly that a record survives the round trip with its
/// fingerprint intact, because a file ssh cannot match would fail closed with an
/// error that looks like a mismatch.
@Suite("known_hosts renderer — canonical record serialization")
struct HostKeyKnownHostsRendererTests {
    private static func record(seed: UInt8) -> HostKeyRecord {
        var key = Data(repeating: 0, count: 32)
        for index in key.indices { key[index] = UInt8(index &+ Int(seed)) }
        var blob = Data()
        let type = Array("ssh-ed25519".utf8)
        blob.append(UInt8((type.count >> 24) & 0xFF))
        blob.append(UInt8((type.count >> 16) & 0xFF))
        blob.append(UInt8((type.count >> 8) & 0xFF))
        blob.append(UInt8(type.count & 0xFF))
        blob.append(contentsOf: type)
        blob.append(contentsOf: [0, 0, 0, 32])
        blob.append(key)
        guard let parsed = HostKeyBlob.parse(blob) else {
            fatalError("test fixture must be a valid SSH host key")
        }
        return HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: .nativeAndOpenSSH
        )
    }

    // MARK: - Host field

    @Test("port 22 is unbracketed and every other port is bracketed")
    func hostFieldBracketing() throws {
        #expect(HostKeyKnownHostsRenderer.hostField(host: "example.com", port: 22) == "example.com")
        #expect(HostKeyKnownHostsRenderer.hostField(host: "example.com", port: 2222)
                == "[example.com]:2222")
        // 0 and 65535 are the extremes; both are non-default.
        #expect(HostKeyKnownHostsRenderer.hostField(host: "h", port: 0) == "[h]:0")
        #expect(HostKeyKnownHostsRenderer.hostField(host: "h", port: 65535) == "[h]:65535")
        // ssh matches hostnames case-insensitively; so must the field.
        #expect(HostKeyKnownHostsRenderer.hostField(host: "Example.COM", port: 22) == "Example.COM")
    }

    // MARK: - Round trip

    @Test("a rendered record survives a round trip with its fingerprint intact")
    func renderedRecordRoundTrips() throws {
        let record = Self.record(seed: 0x41)
        let text = HostKeyKnownHostsRenderer.render(
            host: "roundtrip.test", port: 22, records: [record]
        )

        let entries = HostKeyKnownHostsRenderer.parse(text)
        #expect(entries.count == 1, "one record must render as one key line")

        let entry = try #require(entries.first)
        #expect(entry.hostField == "roundtrip.test")
        #expect(entry.keyType == record.keyType)
        #expect(entry.keyType == "ssh-ed25519")
        #expect(entry.blob == record.keyBlob)
        // The decisive property: the key bytes that come back produce the same
        // fingerprint, so ssh will match the entry we intended to trust.
        #expect(HostKeyBlob.fingerprint(of: entry.blob) == record.fingerprint)
        #expect(HostKeyBlob.validate(record) == nil)
    }

    @Test("a port-2222 entry round trips through its bracketed host field")
    func bracketedPortRoundTrips() throws {
        let record = Self.record(seed: 0x42)
        let text = HostKeyKnownHostsRenderer.render(
            host: "port.test", port: 2222, records: [record]
        )
        let entries = HostKeyKnownHostsRenderer.parse(text)
        #expect(entries.count == 1)
        #expect(entries.first?.hostField == "[port.test]:2222")
    }

    // MARK: - Fail-closed behaviour

    @Test("an empty record set renders no key lines")
    func emptyRecordSetRendersNoKeys() throws {
        let text = HostKeyKnownHostsRenderer.render(
            host: "empty.test", port: 22, records: []
        )
        let entries = HostKeyKnownHostsRenderer.parse(text)
        #expect(entries.isEmpty, "an untrusted host must not gain a key line")
        #expect(text.contains(HostKeyKnownHostsRenderer.emptyFileMarker),
                "the empty file must stay self-describing")
    }

    @Test("a record that disagrees with its own key material is never rendered")
    func inconsistentRecordIsNeverRendered() throws {
        let good = Self.record(seed: 0x43)
        // Fingerprint contradicts the blob. This is the corruption case the
        // renderer must refuse, because ssh would reject it as unparseable at
        // connect time rather than as a mismatch.
        let tampered = HostKeyRecord(
            fingerprint: SSHHostFingerprint(hash: "SHA256:EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"),
            keyType: good.keyType,
            keyBlob: good.keyBlob,
            capability: .nativeAndOpenSSH
        )
        let keyTypeMismatch = HostKeyRecord(
            fingerprint: good.fingerprint,
            keyType: "ssh-rsa",
            keyBlob: good.keyBlob,
            capability: .openSSHOnly
        )

        for bad in [tampered, keyTypeMismatch] {
            let text = HostKeyKnownHostsRenderer.render(
                host: "bad.test", port: 22, records: [bad]
            )
            #expect(
                HostKeyKnownHostsRenderer.parse(text).isEmpty,
                "a record that fails validation must produce no key line"
            )
        }

        // And a valid record in the same list still renders.
        let mixed = HostKeyKnownHostsRenderer.render(
            host: "bad.test", port: 22, records: [tampered, good]
        )
        let entries = HostKeyKnownHostsRenderer.parse(mixed)
        #expect(entries.count == 1, "the valid record must still render")
        #expect(entries.first?.blob == good.keyBlob)
    }

    @Test("an unparseable blob is never rendered")
    func unparseableBlobIsNeverRendered() throws {
        let broken = HostKeyRecord(
            fingerprint: SSHHostFingerprint(hash: "SHA256:FFFF"),
            keyType: "ssh-ed25519",
            keyBlob: Data([0xFF, 0xFF, 0xFF, 0xFF]),
            capability: .nativeAndOpenSSH
        )
        let text = HostKeyKnownHostsRenderer.render(
            host: "broken.test", port: 22, records: [broken]
        )
        #expect(HostKeyKnownHostsRenderer.parse(text).isEmpty,
                "garbage must never reach a trust file")
    }

    // MARK: - Real ssh consumption

    /// The strong test: render, hand the file to the real `/usr/bin/ssh`, and
    /// confirm it *accepts* a matching key and *rejects* a non-matching one.
    ///
    /// A string-level round trip can pass while ssh still rejects the file —
    /// quoting, whitespace and the port bracket are exactly the kinds of detail
    /// that break silently, and this is the only test that would notice.
    @Test("the rendered file is accepted by the real ssh for the recorded key")
    func renderedFileWorksWithRealSSH() async throws {
        let server = try await BenchSSHServer.start(
            hostKeySeed: 0x44,
            password: BenchSSHServerSmokeTests.password,
            sftpDelegate: BenchSFTPDelegate()
        )
        defer { server.stop() }
        let port = UInt16(server.port)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        // Obtain the server's real key the way production would: ssh-keyscan,
        // then build a record from it. That also exercises the renderer against a
        // genuine key rather than a synthetic fixture.
        let scan = Process()
        scan.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        scan.arguments = ["-T", "10", "-t", "ed25519", "-p", String(port), "127.0.0.1"]
        let scanOut = Pipe()
        scan.standardOutput = scanOut
        scan.standardError = Pipe()
        scan.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        try scan.run()
        let scanText = String(decoding: scanOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        scan.waitUntilExit()

        guard let scanLine = scanText.components(separatedBy: .newlines).first(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                && trimmed.split(separator: " ").count >= 3
        }) else {
            Issue.record("ssh-keyscan returned no key for the live fixture")
            return
        }

        let fields = scanLine.split(separator: " ").map(String.init)
        let blob = Data(base64Encoded: fields[2]) ?? Data()
        let parsed = try #require(HostKeyBlob.parse(blob))
        let record = HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: .nativeAndOpenSSH
        )

        let rendered = HostKeyKnownHostsRenderer.render(
            host: "127.0.0.1", port: port, records: [record]
        )
        let renderedPath = dir.appendingPathComponent("known_hosts").path
        try Data(rendered.utf8).write(to: URL(fileURLWithPath: renderedPath))
        // 0600, matching what the canonical store uses for its own files.
        _ = chmod(renderedPath, mode_t(0o600))

        let algorithms = HostKeyBlob.signatureAlgorithms(forKeyType: record.keyType)

        // Run the credential-free probe flag set. Nothing is offered, so the
        // outcome is decided entirely by the host key.
        func probe(knownHosts: String) -> (status: Int32, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-v", "-F", "/dev/null",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(knownHosts)",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "HostKeyAlgorithms=\(algorithms.joined(separator: ","))",
                "-o", "PreferredAuthentications=none",
                "-o", "PubkeyAuthentication=no",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "IdentityFile=none",
                "-o", "IdentityAgent=none",
                "-o", "ConnectTimeout=10",
                "-p", String(port),
                "probe@127.0.0.1", "true",
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment
            let err = Pipe()
            process.standardError = err
            process.standardOutput = Pipe()
            try? process.run()
            let data = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let accepted = probe(knownHosts: renderedPath)
        #expect(
            accepted.stderr.contains("is known and matches the"),
            """
            the real ssh must accept our rendered file. If this fails, the \
            renderer's output is not usable as a trust store and every path \
            downstream would fail closed for the wrong reason. stderr:\n\
            \(accepted.stderr)
            """
        )
        // And it must not be an auth-only refusal, which would mean ssh never
        // verified the key at all.
        #expect(
            !accepted.stderr.contains("Host key verification failed"),
            "ssh rejected the key; the rendered file is not what we intended"
        )

        // A *different* key in the same file must be rejected. This is the one
        // that proves strict checking is actually in force: with `accept-new` or
        // an unrelated entry, ssh would accept anything.
        let otherRecord = Self.record(seed: 0x99)
        let wrongText = HostKeyKnownHostsRenderer.render(
            host: "127.0.0.1", port: port, records: [otherRecord]
        )
        let wrongPath = dir.appendingPathComponent("wrong_kh").path
        try Data(wrongText.utf8).write(to: URL(fileURLWithPath: wrongPath))
        let rejected = probe(knownHosts: wrongPath)
        #expect(
            rejected.stderr.contains("Host key verification failed"),
            """
            a different key must be rejected under strict checking. ssh's stderr \
            shows it was not, so the trust file is not binding the key we \
            recorded:\n\(rejected.stderr)
            """
        )
    }
}