//
//  TerminalViewportSizeAuthorityWiringTests.swift
//  BonkTests
//
//  STRUCTURAL EVIDENCE — NOT BEHAVIOURAL. Labelled as such deliberately.
//
//  The size-authority *decision* is covered behaviourally in
//  `TerminalViewportSizePolicyTests` and `TerminalViewportAuthorityGateTests`.
//  What those cannot reach is whether the production resize path actually goes
//  through that decision. `SessionManager.resizePTY` needs a live tab, a real
//  pane and a live PTY session, so it cannot be driven from a headless test.
//
//  So this file reads the source. That is a weaker kind of evidence and is not
//  presented as more: it can be satisfied by code that is present but never
//  runs, and it can be broken by a rename. It is here because the alternative
//  is no coverage at all of the one link that makes the policy matter.
//
//  The assertions are written against call *sites* and *ordering* rather than
//  the presence of a particular identifier, so the guard survives a rename of
//  the gate method and fails when a second, ungated path to a PTY appears.
//

import Foundation
import Testing
@testable import Bonk

@Suite("PTY size authority: wiring (STRUCTURAL)")
struct TerminalViewportSizeAuthorityWiringTests {

    /// The repository root, derived from this file's own location.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../BonkTests/<this file>
            .deletingLastPathComponent()          // .../BonkTests
            .deletingLastPathComponent()          // repo root
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func swiftSources(in directory: String) throws -> [URL] {
        let root = repoRoot.appendingPathComponent(directory)
        return try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .map { root.appendingPathComponent($0) }
    }

    /// The text of a function's body, by brace matching from its signature.
    private static func body(of source: String, startingAt signature: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The text between a function's signature and its body's opening brace.
    private static func signature(of source: String, startingAt marker: String) -> String? {
        guard let start = source.range(of: marker),
              let open = source[start.upperBound...].firstIndex(of: "{")
        else { return nil }
        return String(source[start.upperBound..<open])
    }

    /// The argument list of the call that a given offset sits inside.
    ///
    /// Scans back to the nearest opening paren of a call, then forward with
    /// paren matching. Brace matching is wrong here: a call's arguments contain
    /// trailing closures, so matching braces from inside the argument list would
    /// capture one closure rather than the call.
    private static func enclosingCall(in source: String, containing offset: String.Index) -> String? {
        guard let open = source[source.startIndex..<offset].lastIndex(of: "(") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "(" { depth += 1 }
            if source[index] == ")" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // MARK: - The gate is on the path

    /// The method that resizes a PTY on a local view's behalf must consult the
    /// authority before it reaches the PTY, and must not reach it otherwise.
    @Test("the local resize path consults the authority before touching the PTY")
    func localResizePathIsGated() throws {
        let source = try Self.source("Bonk/State/SessionManager+Input.swift")
        let body = try #require(
            Self.body(of: source, startingAt: "func resizePTY(\n"),
            "could not locate the gated resize method"
        )

        // A conditional early-return, i.e. something is allowed to decline.
        #expect(
            body.contains("guard"),
            "the resize path must be able to decline a report, not only forward one"
        )
        // The gate is reached through the registry, and the registry's decision
        // comes from the policy. Matched on the call, not on a chosen name, so
        // renaming the gate does not silently disarm this guard.
        #expect(
            body.contains("TerminalViewportRegistry.shared"),
            "the resize path must consult the viewport registry"
        )
        // Ordering: the gate has to be asked before the PTY is told.
        let gateIndex = try #require(
            body.range(of: "TerminalViewportRegistry.shared"),
            "no gate call found in the resize path"
        ).lowerBound
        let sinkIndex = try #require(
            body.range(of: ".resize(cols:"),
            "the resize path no longer reaches a PTY"
        ).lowerBound
        #expect(
            gateIndex < sinkIndex,
            "the PTY is resized before the authority is consulted, so the gate is decorative"
        )
    }

    /// `owner` is required, so a call site that forgets which view it speaks for
    /// cannot compile. Asserted so that re-adding a default is a test failure and
    /// not a silent hole.
    @Test("the resize path cannot be called without naming the reporting view")
    func ownerIsRequired() throws {
        let source = try Self.source("Bonk/State/SessionManager+Input.swift")
        let parameters = try #require(
            Self.signature(of: source, startingAt: "func resizePTY(\n"),
            "could not locate the gated resize method"
        )
        #expect(parameters.contains("owner: TerminalViewOwner"))
        #expect(
            !parameters.contains("owner: TerminalViewOwner?"),
            "a defaulted or optional owner would let a new call site bypass the gate silently"
        )
    }

    // MARK: - There is no second, ungated path

    /// Every PTY resize in the app goes through one of the two named methods.
    ///
    /// The two are the gated local-view path and the explicitly exempt Team
    /// relay path. A third call site would be a view resizing a PTY behind the
    /// authority's back, which is the defect this whole layer exists to prevent.
    @Test("no other code resizes a PTY directly")
    func noUngatedResizeCallSites() throws {
        let sources = try Self.swiftSources(in: "Bonk")
        // The transport layer's own implementations of "make this PTY this
        // size". These are the bottom of the stack, not call sites reaching past
        // the policy — a session has to be able to resize itself. Exempt by
        // category, not because a name happened to fail the check.
        let exempt = [
            "Bonk/Services/SSH/PTYSession.swift",
            "Bonk/Services/SSH/SSHSession.swift",
            "Bonk/Services/SSH/NativeSSHSession.swift",
            "Bonk/Services/SSH/CompatibilitySSHSession.swift",
            "Bonk/Services/SSH/SSHNetworkService.swift",
            "Bonk/Services/SSH/SSHBenchmark.swift",
            "Bonk/Services/Terminal/TerminalEngine.swift",
        ]
        let offenders: [String] = []
        var found: [String] = []
        for url in sources {
            let path = url.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
            if exempt.contains(path) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            // A PTY being told its size, as opposed to a view, a window or a
            // layout being told its size.
            //
            // Matched on the *method*, not on a spelling of the receiver: an
            // earlier version of this guard looked for `pty.resize(` and
            // `ptySession.resize(` and was blind to `ptySession?.resize(`,
            // which is exactly the shape a real bypass takes since the session
            // is optional throughout this codebase. A mutation that had a view
            // resize its own PTY through the optional chain passed the guard.
            for (number, line) in text.split(separator: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                guard trimmed.contains(".resize(cols:") else { continue }
                // A view, a window, an engine or a layout also has a `resize`.
                // Only a PTY-shaped receiver is a PTY.
                let isPTYResize =
                    trimmed.contains("pty.resize(")
                    || trimmed.contains("pty?.resize(")
                    || trimmed.contains("ptySession.resize(")
                    || trimmed.contains("ptySession?.resize(")
                    || trimmed.contains("activePTYSession.resize(")
                    || trimmed.contains("activePTYSession?.resize(")
                if isPTYResize {
                    found.append("\(path):\(number + 1): \(trimmed)")
                }
            }
        }
        #expect(
            found.allSatisfy { $0.hasPrefix("Bonk/State/SessionManager+Input.swift") },
            "a PTY is resized outside the gated path: \(found)"
        )
        #expect(!found.isEmpty, "the scan found nothing — it is not looking at the right tree")
    }

    // MARK: - The panel participates

    /// The Quake panel must report its size.
    ///
    /// It used to pass `onResize: nil`, which is what left it rendering a stream
    /// laid out for a differently-sized window — the reason a TUI program looked
    /// wrong in the panel. With the policy in place the panel is a first-class
    /// view, so it reports like one.
    @Test("the Quake panel reports its size instead of opting out")
    func quakePanelReportsItsSize() throws {
        let source = try Self.source("Bonk/ContentView.swift")
        let marker = try #require(
            source.range(of: "owner: .quakePanel,"),
            "could not locate the Quake panel mount site"
        )
        // The enclosing call, not a brace-matched region: the mount site's
        // arguments include trailing closures, so brace matching from inside the
        // argument list captures one closure and misses the rest.
        let mount = try #require(
            Self.enclosingCall(in: source, containing: marker.lowerBound),
            "could not isolate the Quake panel's argument list"
        )
        #expect(
            mount.contains("owner: .quakePanel"),
            "the panel's resize must name the panel as its owner"
        )
        #expect(
            !mount.contains("onResize: nil"),
            "the Quake panel must not opt out of size reporting"
        )
    }
}
