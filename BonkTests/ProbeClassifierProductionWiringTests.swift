import Foundation
import Testing
@testable import Bonk

/// The probe-classifier link, and the absence of a test-only copy of it.
///
/// ## The failure this prevents
///
/// `ProbeOutcomeClassifierTests.swift` originally defined its *own*
/// `ProbeOutcome` and `ProbeOutcomeClassifier` so the classifier could be
/// exercised before the production probe existed. When the classifier moved into
/// `Bonk/Services/SSH/ProbeOutcomeClassifier.swift`, the test copy stayed behind.
///
/// That is the exact shape this audit keeps finding: a helper that proves the
/// right thing while production does something else. Five scenarios classified
/// correctly against the test copy, and nothing in the suite would have noticed
/// if `HostKeyProbe` had stopped calling the production classifier — or had
/// called it with different arguments, or inverted its result.
///
/// Three things are therefore required, and none of them is "the tests pass":
///
///  1. **One declaration.** Source-scanned, so reintroducing a copy is a failure
///     rather than a silent shadow.
///  2. **The production probe is the thing under test.** Every scenario drives
///     `HostKeyProbe.probe`, not the classifier directly.
///  3. **A mutation turns it red.** If the production classifier is weakened,
///     these tests must notice — which they cannot do if they are looking at a
///     copy.
@Suite("AUDIT-FIND-001 — the probe calls the production classifier, and there is only one")
struct ProbeClassifierProductionWiringTests {
    // MARK: - 1. Exactly one classifier

    @Test("no second classifier or probe exists outside the production sources")
    func theClassifierIsDeclaredOnce() throws {
        let root = Self.sourceRoot()
        let productionFiles = try Self.swiftFiles(in: root).filter { !$0.contains("/BonkTests/") }
        let testFiles = try Self.swiftFiles(in: root).filter { $0.contains("/BonkTests/") }

        /// Declarations that must not be duplicated anywhere.
        let forbidden = [
            "enum ProbeOutcomeClassifier",
            "enum ProbeOutcome:",
            "struct HostKeyProbe",
            "enum HostKeyProbe",
        ]

        for file in productionFiles + testFiles {
            // This gate necessarily names the declarations it forbids, in its own
            // needle array. Scanning itself would fail for the reason it exists to
            // prevent, so it is excluded by path — not by pattern, which would be
            // easy to defeat by renaming.
            if file.hasSuffix("/BonkTests/ProbeClassifierProductionWiringTests.swift") { continue }

            let source = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
            let isTheProductionFile = file.hasSuffix("/Bonk/Services/SSH/ProbeOutcomeClassifier.swift")
                || file.hasSuffix("/Bonk/Services/SSH/HostKeyProbe.swift")
            for declaration in forbidden {
                let occurrences = Self.countOccurrences(of: declaration, in: source)
                guard occurrences > 0 else { continue }
                #expect(
                    isTheProductionFile,
                    """
                    \(declaration) is declared in \(file), which is not the \
                    production source. A second classifier is the failure mode this \
                    suite exists to prevent: the tests would classify correctly while \
                    production did something else.
                    """
                )
            }
        }

        // And the production declarations must actually exist.
        let classifier = try String(
            contentsOf: URL(fileURLWithPath: root + "/Bonk/Services/SSH/ProbeOutcomeClassifier.swift"),
            encoding: .utf8
        )
        #expect(classifier.contains("public enum ProbeOutcomeClassifier"),
                "the production classifier is missing from its own file")
    }

    // MARK: - 2. Production is what the observation suite drives

    @Test("the observation suite drives HostKeyProbe, not the classifier directly")
    func observationSuiteExercisesTheProductionProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: Self.sourceRoot() + "/BonkTests/ProbeOutcomeClassifierTests.swift"),
            encoding: .utf8
        )
        #expect(
            source.contains("HostKeyProbe("),
            """
            the observation suite must build a real HostKeyProbe. A suite that calls \
            ProbeOutcomeClassifier.classify directly proves the classifier is correct \
            in isolation and says nothing about whether the probe uses it.
            """
        )
        #expect(
            !source.contains("ProbeOutcomeClassifier.classify("),
            """
            the observation suite calls ProbeOutcomeClassifier.classify directly, so \
            its observations are not evidence about the production probe.
            """
        )
    }

    // MARK: - 3. The link is real, including failure classifications

    /// A probe against a trust file the probe itself could not write must be
    /// `inconclusive`, never an acceptance.
    ///
    /// This is the failure classification that is easiest to lose, because it
    /// needs no network: `HostKeyProbe` returns `.inconclusive` when the trust
    /// file cannot be created, and a classifier that had drifted would happily
    /// return something else for an empty stderr.
    @Test("a probe with no reachable trust file classifies as inconclusive, not accepted")
    func unwritableTrustFileIsInconclusive() async {
        let probe = HostKeyProbe()
        let outcome = await probe.probe(
            host: "127.0.0.1",
            port: 22,
            // A record whose blob is structurally valid but whose host is a
            // port nothing listens on: the probe must not turn that into trust.
            candidate: HostKeyRecord(
                fingerprint: SSHHostFingerprint(hash: "SHA256:" + String(repeating: "A", count: 43)),
                keyType: "ssh-ed25519",
                keyBlob: Self.anyEd25519Blob,
                capability: .nativeAndOpenSSH
            ),
            timeout: .seconds(5)
        )
        #expect(
            outcome == .inconclusive,
            "a probe that reached no host-key decision must be inconclusive; got \(outcome)"
        )
    }

    /// A timed-out probe is inconclusive regardless of what stderr says.
    ///
    /// The timeout short-circuit is checked first in the classifier, before the
    /// trust-file check and before the positive-match check. If that ordering is
    /// ever lost, a stalled probe that happened to print
    /// `Found key in …` would authorise a trust write.
    @Test("the timeout short-circuit precedes every marker check")
    func timeoutShortCircuitsEveryMarker() {
        let misleadingStderr = """
        debug1: host key is known and matches the pinned key
        debug1: Found key in /tmp/known_hosts:1
        Host key verification failed.
        """
        #expect(
            ProbeOutcomeClassifier.classify(status: 255, timedOut: true, stderr: misleadingStderr) == .inconclusive,
            "a timed-out probe must be inconclusive even when stderr carries accept markers"
        )
    }

    /// The trust-file check precedes the rejection check.
    ///
    /// A corrupt trust file ends on the same final line as a genuine mismatch.
    /// Reading that as `keyRejected` would report "we caught a bad key" when the
    /// truth is "we could not read our own file" — a false security claim.
    @Test("an unusable trust file is inconclusive, never a rejection")
    func unusableTrustFileIsNotARejection() {
        let stderr = """
        Could not open user known hosts file /tmp/kh: No such file or directory
        debug1: hostkeys file is not readable
        Host key verification failed.
        """
        #expect(
            ProbeOutcomeClassifier.classify(status: 255, timedOut: false, stderr: stderr) == .inconclusive,
            "an unreadable trust file proves nothing about the server"
        )
        // And the genuine mismatch, with no trust-file complaint, is a rejection.
        #expect(
            ProbeOutcomeClassifier.classify(
                status: 255, timedOut: false,
                stderr: "@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@\nHost key verification failed."
            ) == .keyRejected,
            "a genuine mismatch must classify as keyRejected"
        )
    }

    /// `Permission denied` alone must never be read as acceptance.
    ///
    /// This is the silent-downgrade case the classifier exists for: under
    /// `accept-new`, ssh adds an unverified key and then refuses authentication,
    /// so the *only* marker is `Permission denied`.
    @Test("an authentication refusal with no positive marker is inconclusive, not accepted")
    func authRefusalAloneIsNotAcceptance() {
        let stderr = "bench@127.0.0.1: Permission denied (publickey,password)."
        #expect(
            ProbeOutcomeClassifier.classify(status: 255, timedOut: false, stderr: stderr) != .keyAcceptedAuthenticationRefused,
            """
            an authentication refusal was classified as key acceptance. Under \
            accept-new this is exactly the downgrade the probe exists to prevent: \
            ssh adds an unverified key and then refuses auth, so 'Permission denied' \
            is the only marker present.
            """
        )
        #expect(
            ProbeOutcomeClassifier.classify(status: 255, timedOut: false, stderr: stderr) == .inconclusive
        )
    }

    // MARK: - Fixture data

    /// Any structurally valid ed25519 blob. Never used as a trust decision — only
    /// as something to render into a trust file for a host that does not exist.
    static let anyEd25519Blob = Data(base64Encoded:
        "AAAAC3NzaC1lZDI1NTE5AAAAIA11UHVOCACl0jfu9YJgNXZrmz5aFYaKlAqyiZWHiOOw"
    )!

    // MARK: - Source scanning helpers

    /// The repository root, from this file's own compile-time path.
///
/// `#filePath` rather than walking up from the bundle: the test bundle runs out
/// of `/tmp/bonk-dd/…` for DerivedData, which is not under the checkout at all,
/// so a bundle-based walk finds nothing and traps. The first version of this did
/// exactly that and crashed with a stack frame in Swift Testing's runner, which
/// is a thoroughly uninformative way to learn that a path helper was wrong.
static func sourceRoot() -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BonkTests
        .deletingLastPathComponent()   // repository root
        .path
}

    static func swiftFiles(in root: String) throws -> [String] {
        var found: [String] = []
        // Bounded to the two directories that matter, so a DerivedData walk
        // cannot drag in build products.
        for relative in ["Bonk", "BonkTests"] {
            guard let walker = FileManager.default.enumerator(
                atPath: root + "/" + relative
            ) else { continue }
            for case let file as String in walker where file.hasSuffix(".swift") {
                found.append(root + "/" + relative + "/" + file)
            }
        }
        return found
    }

    /// Count *declarations* of a type, not mentions of its name.
    ///
    /// Two filters, both necessary. Comment lines are skipped because several of
    /// these files discuss the forbidden declarations in prose. And the needle must
    /// appear at the start of a declaration — otherwise this gate's own `forbidden`
    /// array, which holds the same strings as literals, matches itself and the
    /// suite fails for the reason it exists to prevent.
    static func countOccurrences(of needle: String, in source: String) -> Int {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(into: 0) { count, line in
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return }
                guard trimmed.contains(needle) else { return }
                // A declaration starts the line, modulo access and final markers.
                var head = Substring(trimmed)
                while let first = head.first,
                      first == " " || head.hasPrefix("public ")
                        || head.hasPrefix("final ") || head.hasPrefix("package ") {
                    head = head.dropFirst()
                }
                if head.hasPrefix(needle) { count += 1 }
            }
    }
}