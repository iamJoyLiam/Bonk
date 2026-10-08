import Foundation
import Testing
@testable import Bonk

/// `SSHKeyGenerator` had **no** test coverage before this file. That is why an
/// ignored `passphrase:` parameter, five `-N <secret>` argv sites and a silent
/// `try?` downgrade could all sit here unnoticed — and why the functional
/// baseline below is written before any security mutation: it defines what the
/// generator is supposed to do, so a security change cannot pass by disabling
/// the feature.
///
/// Three contracts, deliberately not collapsed into one:
///
///   1. Secret delivery   — the passphrase exists, is 0600, and reaches the
///                          subprocess only as a file path.
///   2. Invocation        — argv and the environment contain no secret, for any
///                          key type. Structural, so it holds before generation.
///   3. Functional        — nil passphrase yields a usable unencrypted key; an
///                          explicit one yields a key that requires it.
///
/// The passphrase appears in argv of `ssh-keygen -y` below. That is confined to
/// this verification step and is not the product's delivery path.
@Suite("SSH key generator")
struct SSHKeyGeneratorPassphraseTests {
    private static let sentinel = "SUPER_SECRET_SENTINEL_123"

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonk-keygen-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// True when `ssh-keygen -y` can derive the public key using `passphrase`.
    /// Asks the tool rather than inspecting our own formatting.
    private func opens(with passphrase: String, key keyPEM: String) throws -> Bool {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key")
        // `generate` returns the PEM trimmed, so it has no trailing newline and
        // ssh-keygen refuses to parse it. That made every `opens(...)` assertion
        // report false for a correctly generated key — a broken verification
        // helper masquerading as a generation failure.
        try Data((keyPEM + "\n").utf8).write(to: path)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path.path
        )

        let out = Pipe()
        let err = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-y", "-P", passphrase, "-f", path.path]
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        // Drain both pipes before waiting. An undrained pipe can wedge the child
        // once its buffer fills, and the reads must finish before the reaping
        // `waitUntilExit` returns.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let status = proc.terminationStatus
        if status != 0 {
            // This harness does not forward stdout/stderr, so the reason a
            // verification step failed is written where it survives.
            let mode = (try? FileManager.default
                .attributesOfItem(atPath: path.path)[.posixPermissions]) ?? "?"
            let report = """
            status=\(status) passLen=\(passphrase.count)
            pemHead=\(keyPEM.prefix(30).debugDescription) pemBytes=\(keyPEM.utf8.count)
            fileMode=\(mode)
            stderr=\(String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
            stdout=\(String(decoding: outData, as: UTF8.self).prefix(40).debugDescription)
            """
            let diagPath = "/private/var/folders/ql/gl8fnjcs0v90czmxh7h4rlqr0000gn/T/opencode/opens-diag.txt"
            let existing = (try? String(contentsOfFile: diagPath, encoding: .utf8)) ?? ""
            try? Data((existing + report + "\n---\n").utf8)
                .write(to: URL(fileURLWithPath: diagPath))
        }
        return status == 0
    }

    /// Whether `keyPEM` is a private key protected by exactly `passphrase`.
    ///
    /// `ssh-keygen -y -P X` does not verify `X` against an unencrypted key — it
    /// ignores it and succeeds. So success alone cannot distinguish "encrypted
    /// with P" from "not encrypted at all", and a test asserting only the first
    /// half passes on a fully downgraded key. Requiring an unrelated passphrase to
    /// be rejected is what makes the property falsifiable.
    private func encrypted(with passphrase: String, key keyPEM: String) throws -> Bool {
        guard try opens(with: passphrase, key: keyPEM) else { return false }
        return try !opens(with: "unrelated-\(UUID().uuidString)", key: keyPEM)
    }

    // MARK: - 1. Secret delivery

    @Test("The secret lands in a 0600 file with its exact bytes")
    func secretFileIsPrivateAndExact() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secretPath = try SSHKeyGenerator.writeSecret(
            Array(Self.sentinel.utf8), in: dir
        )

        #expect(FileManager.default.fileExists(atPath: secretPath.path))
        #expect(try mode(of: secretPath.path) == 0o600,
                "the secret file must not be group or world readable")

        // Exact, modulo the trailing newline ssh-keygen needs to read a line.
        let written = try String(contentsOf: secretPath, encoding: .utf8)
        #expect(written == Self.sentinel + "\n",
                "the file must hold the passphrase verbatim plus one newline")
    }

    @Test("The askpass helper reads by path and ignores OpenSSH's prompt argument")
    func helperReadsByPathOnly() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secretPath = dir.appendingPathComponent("secret")
        let helper = SSHKeyGenerator.makeAskpassHelper(secretPath: secretPath)

        #expect(!helper.contains(Self.sentinel))
        #expect(helper.contains("cat"))
        #expect(helper.contains(secretPath.path))
        // argv[1] is the prompt; the helper must never consume it as the secret.
        #expect(!helper.contains("$1"))
    }

    // MARK: - 2. Invocation contract — no secret in argv or environment

    @Test("No key type puts a passphrase in argv or the environment")
    func invocationNeverCarriesTheSecret() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secretPath = try SSHKeyGenerator.writeSecret(
            Array(Self.sentinel.utf8), in: dir
        )
        let helperPath = try SSHKeyGenerator.writeAskpassHelper(
            secretPath: secretPath, in: dir
        )
        let additions = SSHKeyGenerator.makeAskpassEnvironment(helperPath: helperPath)

        #expect(!additions.values.contains { $0.contains(Self.sentinel) },
                "the environment carries only paths")

        for type in SSHKeyType.allCases {
            let arguments = SSHKeyGenerator.makeArguments(
                type: type, keyPath: dir.appendingPathComponent("key")
            )
            for argument in arguments {
                #expect(!argument.contains(Self.sentinel),
                        "\(type.rawValue): the passphrase reached argv — \(argument)")
            }
            #expect(!arguments.contains("-N"),
                    "\(type.rawValue): -N would carry the passphrase as argv")
        }

        // Delivery is real, so the assertions above are not passing because the
        // secret was dropped on the floor.
        #expect(try String(contentsOf: secretPath, encoding: .utf8)
            .contains(Self.sentinel))
    }

    // MARK: - 3. Functional contract

    @Test("No passphrase requested yields a usable unencrypted key")
    func nilPassphraseProducesUsableKey() throws {
        let key = try SSHKeyGenerator.generate(type: .ed25519, passphrase: nil)

        #expect(!key.privateKeyPEM.isEmpty)
        #expect(!key.publicKeySSH.isEmpty)
        #expect(!key.fingerprint.isEmpty)
        // Decides which path ran. A CryptoKit fallback key is not in OpenSSH
        // format, so this distinguishes "ssh-keygen was used" from "ssh-keygen
        // threw, `try?` hid it, and the unencrypted fallback answered".
        #expect(key.privateKeyPEM.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
                "ssh-keygen was not the path that produced this key")
        #expect(try opens(with: "", key: key.privateKeyPEM),
                "an unprotected key must open with no passphrase")
    }

    @Test("An explicit passphrase yields a key that requires that passphrase")
    func explicitPassphraseProducesEncryptedKey() throws {
        let passphrase = "sentinel-\(UUID().uuidString)"
        let key = try SSHKeyGenerator.generate(type: .ed25519, passphrase: passphrase)

        #expect(try encrypted(with: passphrase, key: key.privateKeyPEM),
                "the key must be protected by exactly the requested passphrase")
    }

    /// Every key type must still generate, so a security change cannot pass by
    /// quietly narrowing what works.
    @Test("All key types still generate without a passphrase")
    func allKeyTypesStillGenerate() throws {
        for type in SSHKeyType.allCases {
            let key = try SSHKeyGenerator.generate(type: type, passphrase: nil)
            #expect(!key.privateKeyPEM.isEmpty, "\(type.rawValue) produced no key")
        }
    }

    /// P1-b's fail-closed contract: a requested passphrase is either honoured or
    /// the operation is rejected. An unencrypted key is never an acceptable
    /// outcome.
    @Test("A requested passphrase is never silently downgraded")
    func requestedPassphraseIsNeverDowngraded() throws {
        let passphrase = "sentinel-\(UUID().uuidString)"
        let key: GeneratedSSHKey
        do {
            key = try SSHKeyGenerator.generate(type: .ed25519, passphrase: passphrase)
        } catch {
            // Only a refusal by production counts as failing closed. The
            // verification helper must not be inside this block: previously it
            // was, so a throwing helper read as a legitimate rejection and the
            // test could not tell the two apart.
            #expect(error is SSHKeyGeneratorError, "unexpected error type: \(error)")
            return
        }

        // Deliberately outside the do/catch above, so a helper failure surfaces as
        // a test error rather than being absorbed as fail-closed behaviour.
        #expect(
            try encrypted(with: passphrase, key: key.privateKeyPEM),
            """
            a passphrase was requested and generation succeeded, but the key is \
            not protected by it — the request was downgraded instead of rejected
            """
        )
    }
}
