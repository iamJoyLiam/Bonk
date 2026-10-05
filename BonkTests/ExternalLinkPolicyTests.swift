//
//  ExternalLinkPolicyTests.swift
//  BonkTests
//
//  Which links a terminal is allowed to hand to `NSWorkspace.open`.
//
//  Both terminal surfaces use this: the main terminal, whose content comes
//  from the machine the user typed at, and the team guest terminal, whose
//  content comes from a machine that has not been authenticated beyond a
//  shared PIN. A link in either is a request to run something, because
//  `NSWorkspace.open` dispatches to whatever handler claims the scheme.
//
//  The guest surface previously had no allowlist at all — `URL(string:)` and
//  straight to `open`. These tests are what makes that distinction testable at
//  all; there is no SwiftUI harness in this project, so a delegate-level test
//  could only have been a source guard.
//

import Foundation
import Testing
@testable import Bonk

@Suite("External Link Policy Tests")
struct ExternalLinkPolicyTests {

    // MARK: - Permitted

    @Test("Web links are allowed")
    func webLinksAllowed() throws {
        let https = try #require(ExternalLinkPolicy.resolve("https://example.com"))
        #expect(https.scheme == "https")
        #expect(https.host == "example.com")

        let http = try #require(ExternalLinkPolicy.resolve("http://example.com/path?q=1"))
        #expect(http.scheme == "http")
        #expect(http.host == "example.com")
    }

    /// Scheme matching is case-insensitive, because the parser preserves the
    /// case the remote host chose. `HTTP://` is the same scheme as `http://`
    /// and refusing it would train users to click anyway.
    @Test("Scheme case does not matter")
    func schemeCaseInsensitive() throws {
        #expect(ExternalLinkPolicy.resolve("HTTPS://example.com") != nil)
        #expect(ExternalLinkPolicy.resolve("HtTp://example.com") != nil)
    }

    /// A bare host is what users actually type. It is filled in as https and
    /// then checked like any other value — a convenience, not a bypass, because
    /// the substituted value never enters the system without passing the filter.
    @Test("A bare host is filled in as https")
    func bareHostBecomesHTTPS() throws {
        let resolved = try #require(ExternalLinkPolicy.resolve("example.com"))
        #expect(resolved.scheme == "https")
        #expect(resolved.host == "example.com")

        // Path, query and fragment must survive the completion, or the
        // convenience silently drops what the link pointed at.
        let deep = try #require(ExternalLinkPolicy.resolve("example.com/a/b?q=1#frag"))
        #expect(deep.host == "example.com")
        #expect(deep.path == "/a/b")
        #expect(deep.query == "q=1")
        #expect(deep.fragment == "frag")
    }

    // MARK: - Refused

    /// The schemes that make this more than a nuisance: they read local
    /// paths, reach network shares, and launch other applications.
    @Test("Schemes that act on the local machine are refused")
    func localActingSchemesRefused() {
        for link in [
            "file:///etc/passwd",
            "file:///Users/joyliam/.ssh/id_ed25519",
            "smb://attacker.example/share",
            "itms-apps://itunes.apple.com/app/id000",
            "x-apple.systempreferences:com.apple.preference.security",
        ] {
            #expect(ExternalLinkPolicy.resolve(link) == nil,
                    "\(link) must not reach the system URL handler")
        }
    }

    /// `URLComponents` reads `example.com:8080` as scheme `example.com`. That is
    /// why a bare host has to be completed by splitting `path` rather than by
    /// setting a scheme on the parsed components: the latter turns `example.com`
    /// into `https:example.com`, which has no host at all and is not the link
    /// the user meant. Locked down because getting it wrong is silent — the
    /// link still "resolves", just to somewhere else.
    @Test("A bare host is completed by rebuilding the authority, not by tagging a scheme")
    func bareHostCompletionIsStructural() throws {
        // Would-be authority in the host position of a no-scheme input.
        let resolved = try #require(ExternalLinkPolicy.resolve("example.com"))
        #expect(resolved.absoluteString == "https://example.com",
                "a bare host must become a real authority, not the opaque \(resolved.absoluteString)")
    }

    @Test("Other handlers are refused")
    func otherSchemesRefused() {
        for link in [
            "ftp://example.com",
            "data:text/html,<script>alert(1)</script>",
            "javascript:alert(1)",
            "mailto:someone@example.com",
        ] {
            #expect(ExternalLinkPolicy.resolve(link) == nil, "\(link) must not be opened")
        }
    }

    /// The substitution must not become the bypass. A link whose scheme is
    /// absent gets https appended; a link whose scheme is present but not
    /// allowed is refused outright, and is never "fixed" by the substitution.
    @Test("A disallowed scheme is not replaced by the bare-host rule")
    func disallowedSchemeIsNotSubstituted() {
        // Contains no scheme separator before the colon, so `URLComponents`
        // parses `file` as the scheme — not as a bare host.
        #expect(ExternalLinkPolicy.resolve("file:host") == nil)
        #expect(ExternalLinkPolicy.resolve("javascript:void(0)") == nil)
        // And the filled-in form is still checked: no path here yields a
        // permitted URL.
        #expect(ExternalLinkPolicy.resolve("smb://") == nil)
    }

    @Test("Malformed links are refused rather than guessed at")
    func malformedRefused() {
        for link in ["", "   ", "http://", "https://", "://example.com", "http://:80"] {
            #expect(ExternalLinkPolicy.resolve(link) == nil,
                    "\"\(link)\" must not resolve to something openable")
        }
    }

    /// An empty string is worth calling out: `URLComponents(string: "")` yields
    /// components with no scheme, which the bare-host rule would otherwise
    /// turn into `https://` — a URL that opens an empty page. Refused instead.
    @Test("An empty link does not become an empty https page")
    func emptyLinkRefused() {
        #expect(ExternalLinkPolicy.resolve("") == nil)
    }

    // MARK: - The two surfaces share one policy

    /// The bug was two answers to one question, so the fix has to be one
    /// answer. Structural, and it exists to catch a future edit that
    /// reintroduces a local scheme list next to the shared one.
    @Test("No terminal delegate opens a URL without the shared policy")
    func delegatesGoThroughThePolicy() throws {
        for path in [
            "Bonk/Views/Team/TeamGuestTerminalView.swift",
            "Bonk/Views/Terminal/Container/TerminalContainerView+Delegate.swift",
        ] {
            let source = try String(
                contentsOf: SourceLocator.projectFile(path),
                encoding: .utf8
            )
            #expect(source.contains("ExternalLinkPolicy.resolve(link)"),
                    "\(path) must route links through ExternalLinkPolicy")
            // A hand-rolled `URL(string:)` inside an open-link delegate is
            // exactly what this policy replaced.
            let openLink = try #require(source.range(of: "func requestOpenLink"))
            let scope = String(source[openLink.lowerBound...].prefix(600))
            #expect(!scope.contains("URL(string:"),
                    "\(path) must not parse links directly")
            #expect(!scope.contains("\"http\"") && !scope.contains("\"https\""),
                    "\(path) must not carry its own scheme list")
        }
    }
}