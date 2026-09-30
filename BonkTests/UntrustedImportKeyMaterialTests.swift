//
//  UntrustedImportKeyMaterialTests.swift
//  BonkTests
//
//  An import file is data. It must not be a capability.
//
//  Five importers read a `privateKeyPath` out of a file another application
//  wrote, tilde-expanded it, and opened it as a local file. The path was chosen
//  entirely by the content, and the read happened during `load()` on
//  `.onAppear` — so merely opening the Import sheet read any file the user could
//  read, with no dialog and no path ever shown:
//
//      ~/Library/Keychains/…, ~/.ssh/id_ed25519, ~/.aws/credentials
//
//  The result became the host's key material via `HostItem.init`, which writes
//  the Keychain. So a manifest could nominate a local secret and an
//  attacker-chosen host at the same time.
//
//  Why user selection does not make this safe: `NSOpenPanel` returns a
//  security-scoped URL for the file that was picked. A path *named inside* that
//  file is a different file, and the user never authorised it. So an importer
//  may not read a manifest-supplied path even when the manifest itself was
//  chosen deliberately.
//
//  What is allowed is a key that is *inline* — a PEM literal in the file is
//  data, not a file access. What is refused is a path, and the refusal is
//  recorded rather than silently dropped so the UI can offer to resolve it if a
//  user ever asks.
//
//  These tests assert the outcome, not the absence of a call site: a canary PEM
//  is placed where the manifest says to look, and the assertion is that it never
//  reaches the host's key material. A test that only checked "the path does not
//  exist" would pass against a fix that moved the read to a different lifecycle
//  callback; this one cannot.
//

import Foundation
import Testing
@testable import Bonk

@Suite("An import manifest cannot grant local file access")
struct UntrustedImportKeyMaterialTests {

    /// A PEM that exists only to be detected. Never a real key.
    private static let canary = "CANARY-NOT-A-REAL-KEY-----BEGIN OPENSSH PRIVATE KEY-----"

    /// A manifest naming a local file, with no inline password, so that
    /// `HostItem.init` stores nothing unless the importer resolved the path.
    private func manifest(host: String, keyPath: String) -> [String: Any] {
        [
            "title": "attacker-chosen-name",
            "host": host,
            "username": "root",
            "port": 22,
            "privateKeyPath": keyPath,
        ]
    }

    /// Write the canary somewhere an importer would be willing to read.
    private func makeCanaryKey() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-canary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("id_ed25519")
        try Self.canary.write(to: key, atomically: true, encoding: .utf8)
        return key
    }

    private func writeManifest(_ name: String, _ objects: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: objects)
        try data.write(to: url)
        return url
    }

    /// Remove every Keychain entry these hosts created, whatever the outcome.
    ///
    /// `HostItem.init` writes the Keychain, so a red run against the unfixed
    /// importer stores the canary under a real account name. Without this the
    /// test would leave key-shaped residue in the user's login keychain.
    private func scrub(_ hosts: [HostItem]) {
        for host in hosts {
            KeychainHelper.delete(for: KeychainHelper.privateKeyKey(for: host.id))
            KeychainHelper.delete(for: KeychainHelper.passwordKey(for: host.id))
        }
    }

    // MARK: - The gap

    @Test("a manifest naming a local key file does not import its contents")
    func manifestPathIsNotRead() throws {
        let keyURL = try makeCanaryKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        // Electerm reads bookmarks.json as a top-level array.
        let manifest = try writeManifest("bookmarks.json", [manifest(host: "evil.example", keyPath: keyURL.path)])
        let hosts: [HostItem]
        do {
            hosts = try ElectermImporter().importSessions(from: manifest)
        } catch {
            Issue.record("the manifest itself should still parse")
            return
        }
        defer { scrub(hosts) }

        let imported = hosts.first { $0.host == "evil.example" }
        #expect(imported != nil, "the host entry itself is still data worth importing")

        let storedKey = imported?.loadPrivateKey()
        #expect(
            storedKey?.contains("CANARY") != true,
            "a path named by an untrusted manifest must not be read into key material"
        )
        #expect(
            imported?.authType != .privateKey,
            "no key was authorised, so the host must not be imported as key-based"
        )
    }

    /// The same shape through the CSV importer, which has its own copy of the
    /// read. Covering one importer would leave the others live.
    @Test("the CSV importer does not read a manifest-named path either")
    func csvImporterPathIsNotRead() throws {
        let keyURL = try makeCanaryKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sessions.csv")
        let header = "name,host,username,port,privateKeyPath"
        let row = "attacker-chosen-name,evil.example,root,22,\(keyURL.path)"
        try ([header, row].joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)

        let hosts: [HostItem]
        do {
            hosts = try GenericCSVImporter().importSessions(from: url)
        } catch {
            Issue.record("the CSV itself should still parse")
            return
        }
        defer { scrub(hosts) }

        let imported = hosts.first { $0.host == "evil.example" }
        let stored = imported?.loadPrivateKey()
        #expect(
            stored?.contains("CANARY") != true,
            "a path named by an untrusted manifest must not be read into key material"
        )
        // Stronger than the canary check, and it is what caught a second parse
        // path that stored the *path itself* as the key — the canary lives in the
        // file's contents, so a path being stored verbatim slipped past it.
        #expect(
            stored == nil,
            "no key was authorised, so no key material may exist at all"
        )
        #expect(imported?.authType != .privateKey)
    }

    /// A relative path and a `file://` URL are the same attack with different
    /// spelling; tilde is the shape these manifests actually use in the wild.
    @Test("no path spelling of a manifest-supplied key is resolved")
    func pathSpellingsAreAllRefused() throws {
        let keyURL = try makeCanaryKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let spellings = [
            keyURL.path,
            keyURL.path.replacingOccurrences(of: "/private", with: "~"),
            "file://" + keyURL.path,
            keyURL.lastPathComponent,
        ]
        for spelling in spellings {
            let manifest = try writeManifest(
                "bookmarks.json",
                [manifest(host: "evil.example", keyPath: spelling)]
            )
            let hosts = (try? ElectermImporter().importSessions(from: manifest)) ?? []
            defer { scrub(hosts) }
            #expect(
                hosts.first { $0.host == "evil.example" }?.loadPrivateKey()?.contains("CANARY") != true,
                "a manifest path must never be read, whatever its spelling"
            )
        }
    }

    // MARK: - What is still allowed

    /// The YAML shape, which is a *second* parser in the Tabby importer and was
    /// storing the profile's `privateKeyPath` as the key verbatim.
    ///
    /// Added because mutation M4 — restoring that line — passed the whole suite.
    /// A defect present in a second code path, with no test reaching it, is
    /// exactly the shape that survives review.
    @Test("the Tabby YAML profile path does not become key material")
    func tabbyYAMLPathIsNotRead() throws {
        let keyURL = try makeCanaryKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-yaml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.yaml")
        let yaml = [
            "profiles:",
            "  - name: yaml-host",
            "    host: yaml.example",
            "    port: 22",
            "    user: me",
            "    privateKeyPath: \(keyURL.path)",
        ].joined(separator: "\n")
        try yaml.write(to: url, atomically: true, encoding: .utf8)

        let hosts = (try? TabbyImporter().importSessions(from: url)) ?? []
        defer { scrub(hosts) }

        let imported = hosts.first { $0.host == "yaml.example" }
        #expect(imported != nil, "the profile itself is still data worth importing")
        #expect(
            imported?.loadPrivateKey() == nil,
            "a path named by a Tabby profile must not become key material"
        )
        #expect(imported?.authType != .privateKey)
    }

    /// Refusing a path must not swallow the rest of the record.
    ///
    /// This is here because an intermediate version of the fix left a duplicated,
    /// empty `else if` in the CSV row parser, so a manifest with both a key path
    /// and a password matched the empty branch and the host was dropped without
    /// error. The key-path tests could not see it — their manifests have no
    /// password column.
    @Test("a declined key path does not swallow the password beside it")
    func declinedKeyPathLeavesPasswordIntact() throws {
        let keyURL = try makeCanaryKey()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-csv-pw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sessions.csv")
        let header = "name,host,username,port,password,privateKeyPath"
        let row = "pw-host,pw.example,me,22,s3cret,\(keyURL.path)"
        try ([header, row].joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)

        let hosts = (try? GenericCSVImporter().importSessions(from: url)) ?? []
        defer { scrub(hosts) }

        let imported = hosts.first { $0.host == "pw.example" }
        #expect(imported != nil, "the record must survive a declined key path")
        #expect(imported?.authType == .password)
        #expect(imported?.loadPrivateKey() == nil, "still no key material")
    }

    /// An inline PEM is data in the file, not a file access, and remains
    /// importable. Refusing this too would be a functional regression.
    @Test("an inline key in the manifest is still imported")
    func inlineKeyStillImports() throws {
        let inline = "-----BEGIN OPENSSH PRIVATE KEY-----\ninline\n-----END OPENSSH PRIVATE KEY-----"
        let manifest = try writeManifest("bookmarks.json", [[
            "title": "inline-key",
            "host": "good.example",
            "username": "me",
            "privateKey": inline,
        ]])
        let hosts = (try? ElectermImporter().importSessions(from: manifest)) ?? []
        defer { scrub(hosts) }

        let imported = hosts.first { $0.host == "good.example" }
        #expect(imported != nil)
        #expect(imported?.authType == .privateKey, "an inline PEM is data and stays importable")
        #expect(imported?.loadPrivateKey()?.contains("BEGIN") == true)
    }
}

// MARK: - The primitive itself

/// A structural guard, and labelled as one.
///
/// The behavioural tests above pin the outcome for the importers they drive.
/// This pins the *primitive*: that no importer anywhere in the directory can
/// open a path named inside parsed content, in any lifecycle callback. The
/// failure mode this exists for is a fix that moves the read from `load()` to
/// some other automatic callback, which an outcome test on one entry point would
/// not see.
///
/// It is a source check, so it can be satisfied by code that is present and never
/// runs. That is the accepted limit for a guard on an untestable-by-construction
/// property; the behaviour is covered above.
@Suite("Import manifests hold no local file read (STRUCTURAL)")
struct UntrustedImportReadPrimitiveGuardTests {

    /// The token that marks a local file read by name. See the check below.
    private static let manifestReadToken = "contentsOfFile:"

    @Test("no importer opens a path derived from manifest content")
    func noManifestDerivedFileRead() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BonkTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Bonk/Services/Import")

        // The scan is only as good as its token, and a source guard cannot notice
        // its own token going stale: with the wrong one it finds nothing and
        // reports "clean". The first version of this guard searched for
        // `contentsOfFile(` — a call with parentheses — and passed while all five
        // sites were present, because the real spelling is an argument label with
        // a colon: `String(contentsOfFile: path)`.
        //
        // The token lives in one place and both the scan and this check read it,
        // so changing it here fails the suite instead of silently blinding it.
        #expect(
            Self.manifestReadToken == "contentsOfFile:",
            "the scan token drifted; it must match String(contentsOfFile: path)"
        )
        #expect("String(contentsOfFile: expanded)".contains(Self.manifestReadToken))
        #expect("let text = try String(contentsOf: url)".contains(Self.manifestReadToken) == false,
                "reading the manifest itself is legitimate and must not be flagged")

        let sources = try FileManager.default
            .subpathsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .map { dir.appendingPathComponent($0) }
        #expect(!sources.isEmpty, "the scan found no sources — wrong tree?")

        var offenders: [String] = []
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // Matched as `contentsOfFile:` — an argument label with a
                // colon, not a call with parentheses. The first version of this
                // guard searched for `contentsOfFile(` and found nothing while
                // all five sites were present, so it passed against the defect
                // it exists to catch.
                if trimmed.contains(Self.manifestReadToken) {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            "an importer can still open a manifest-named path: \(offenders)"
        )
    }
}
