//
//  ExternalLinkPolicy.swift
//  Bonk
//
//  Which links a terminal may hand to the system.
//
//  Trust boundary: terminal output is *remote input*. A host you pair with —
//  or anything that host prints — can emit an OSC 8 hyperlink or an implicit
//  URL and get this app to open it. `NSWorkspace.open` is not a browser: it
//  dispatches to whatever handler claims the scheme, so a link is a request to
//  run something, not a request to show a page.
//
//  This type exists because there were two answers to that question and they
//  disagreed. The main terminal restricted links to http/https
//  (`TerminalContainerView+Delegate.swift`); the team guest terminal accepted
//  anything `URL(string:)` could parse. Same app, same product feature, one
//  guest surface no more permissive than the other — and the guest surface is
//  the one whose content comes from a machine the user has not yet fully
//  established.
//
//  The decision is a pure function so it is testable without a running app.
//  Testing it through the view delegate instead would mean a source guard,
//  which is how this class of bug hides in the first place.
//

import Foundation

enum ExternalLinkPolicy {
    /// The only schemes a terminal may hand to the system.
    ///
    /// Deliberately not "anything that looks like a URL". `file://` reads local
    /// paths, `smb://` and `ftp://` reach network shares, and the
    /// `itms*`/`x-apple.*` families launch other applications — a remote host
    /// choosing among those is a remote host choosing what runs on this machine.
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Resolve a link for opening, or refuse it.
    ///
    /// A link with no scheme is treated as a bare host and completed to
    /// `https://host`, so `example.com` behaves the way a terminal user
    /// expects. The completion happens *before* the check rather than after, so
    /// a scheme that is present is never rewritten — otherwise `file:///x` and
    /// a bare host would travel the same path.
    ///
    /// A host is required. Scheme validation alone is not sufficient:
    /// `URLComponents` will happily build `https:` from an empty string and
    /// `https://` from `"http://"`, and those are URLs the system will open.
    /// An allowlist that admits a link with nowhere to go is not a policy.
    static func resolve(_ link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let components = URLComponents(string: trimmed) else { return nil }
        if let scheme = components.scheme {
            // A scheme is present, so this is an absolute link and is judged
            // as one. Note `example.com:8080` parses its first label *as* a
            // scheme; that falls through the filter and is refused, which is
            // the correct answer for a link with no scheme.
            return permitted(components)
        }
        // No scheme: `URLComponents` puts the whole thing in `path`, so the
        // bare host is the first path segment. Split it back out rather than
        // re-parsing, so the authority cannot be reassembled ambiguously.
        let raw = components.percentEncodedPath
        guard !raw.isEmpty else { return nil }
        let segments = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = segments.first, !host.isEmpty else { return nil }
        let tail = segments.count > 1 ? "/" + segments[1] : ""
        guard var rebuilt = URLComponents(string: "https://" + host + tail) else { return nil }
        if let query = components.percentEncodedQuery { rebuilt.percentEncodedQuery = query }
        if let fragment = components.percentEncodedFragment { rebuilt.percentEncodedFragment = fragment }
        return permitted(rebuilt)
    }

    private static func permitted(_ components: URLComponents) -> URL? {
        guard let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              let host = components.host, !host.isEmpty,
              let url = components.url
        else { return nil }
        return url
    }
}