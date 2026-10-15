import Foundation
import NIOCore
import Crypto
@testable import Bonk

/// Shared helpers for the host-key audit suites.
///
/// Extracted from `OpenSSHTrustDecisionDivergenceTests`, which was the AUDIT-FIND-001
/// tier-2 characterisation suite. That suite asserted the *divergence* that is now
/// fixed, so it was converted rather than deleted; its helpers outlive it and are
/// used by the convergence gate, the B-02 fallback gate and the probe-classifier
/// observation suite.
///
/// Lives in its own file so the conversion is a move of helpers, not a
/// reintroduction of the old assertion.

// MARK: - Outcomes
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
// MARK: - Host-key fixture support

/// Helpers for building host-key trust fixtures.
///
/// Shared because several audit suites need the same two things: a temp store,
/// and the key material a live `BenchSSHServer` actually serves.
enum HostKeyFixtureSupport {
    /// A private temp directory that the caller is responsible for removing.
    static func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// The key material a live server actually serves, obtained the way
    /// production obtains candidates: `ssh-keyscan`.
    ///
    /// Nothing about this is trusted. It is the bytes on the wire, used to seed a
    /// store so a later connection can be tested against a *different* key.
    static func scannedKey(port: UInt16) throws -> HostKeyRecord {
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
        }), let blob = Data(base64Encoded: line.split(separator: " ").map(String.init)[2]),
              let parsed = HostKeyBlob.parse(blob)
        else {
            throw HostKeyFixtureError.noKey
        }
        return HostKeyRecord(
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: .nativeAndOpenSSH
        )
    }

    enum HostKeyFixtureError: Error { case noKey }
}

// MARK: - Temp resolvers

extension HostKeyFixtureSupport {
    /// A resolver over a throwaway canonical store.
    ///
    /// Every host-key test must build its backend with one of these. There is no
    /// default resolver by design — see `OpenSSHKnownHostsResolver.production()`
    /// for why — so a test that omits this does not silently reach the user's real
    /// Application Support trust store, it simply fails to compile.
    static func tempResolver(label: String) throws -> (OpenSSHKnownHostsResolver, URL) {
        let directory = try makeTempDir(label)
        let store = try CanonicalHostKeyStore(
            fileURL: directory.appendingPathComponent("records.json")
        )
        return (OpenSSHKnownHostsResolver(store: store), directory)
    }
}

extension HostKeyFixtureSupport {
    /// A structurally valid ed25519 record that no server is serving.
    ///
    /// For gates that need *a stored record* without needing a live listener —
    /// a conflict fixture, most of all. Never used as evidence about a real
    /// host; the point is only that the canonical store holds something concrete.
    static func syntheticEd25519Record(
        fingerprintSeed: Character = "F"
    ) -> HostKeyRecord {
        let blob = Data(base64Encoded:
            "AAAAC3NzaC1lZDI1NTE5AAAAIA11UHVOCACl0jfu9YJgNXZrmz5aFYaKlAqyiZWHiOOw"
        )!
        let parsed = HostKeyBlob.parse(blob)!
        return HostKeyRecord(
            // The parsed fingerprint is the honest one; the seed exists only so a
            // caller can assert two fixtures differ when they must.
            fingerprint: parsed.fingerprint,
            keyType: parsed.keyType,
            keyBlob: blob,
            capability: .nativeAndOpenSSH
        )
    }
}
