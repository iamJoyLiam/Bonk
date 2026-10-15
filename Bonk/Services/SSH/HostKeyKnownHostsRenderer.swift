//
//  HostKeyKnownHostsRenderer.swift
//  Bonk
//
//  Serializes canonical host-key records into the `known_hosts` format OpenSSH
//  understands.
//
//  ## Why a renderer rather than passing fingerprints
//
//  OpenSSH does not have a "trust this digest" mode. `UserKnownHostsFile` is the
//  only way to tell it what to trust, and it needs the public key itself. So the
//  canonical store, which is authoritative, has to be *rendered* into a file ssh
//  can read — the store is never handed to ssh directly, and ssh's own trust file
//  is never read either.
//
//  ## Why the host field is bracketed for non-default ports
//
//  `known_hosts` distinguishes `host` from `[host]:port`. Without the bracket, ssh
//  treats the whole token as a hostname and never matches a non-22 port, so a
//  record for `example.com:2222` would be silently unreachable and the connection
//  would fail closed with a "host key unknown" error that looks like a mismatch.
//

import Foundation

/// Renders canonical records as `known_hosts` content.
public enum HostKeyKnownHostsRenderer {
    /// The marker written when there are no records to render.
    ///
    /// An empty file and a comment-only file are equivalent to ssh, but a comment
    /// makes the generated file self-describing in a diagnostic trace, and — more
    /// importantly — lets a test distinguish "rendered nothing" from "wrote an
    /// empty file by accident".
    public static let emptyFileMarker = "# rendered by Bonk from canonical host-key records; no records"

    /// Render one host's records.
    ///
    /// - Parameters:
    ///   - host: the hostname as ssh will see it. Lower-cased, since a hostname
    ///     is case-insensitive and a mismatch would make the entry unreachable.
    ///   - port: the port, written bracketed when it is not 22.
    ///   - algorithmOverride: signature algorithms to restrict ssh to. Passed
    ///     through to `HostKeyBlob.signatureAlgorithms` when nil. Callers that
    ///     need to override must do so explicitly; this default keeps the
    ///     renderer from silently widening the accepted key set.
    public static func render(
        host: String,
        port: UInt16,
        records: [HostKeyRecord]
    ) -> String {
        let hostField = hostField(host: host, port: port)
        var lines: [String] = []

        for record in records {
            // Re-validate: a record that disagrees with its own key material must
            // never reach a trust file, however it got into the list.
            guard HostKeyBlob.validate(record) == nil else { continue }
            lines.append(contentsOf: [
                "# \(record.fingerprint.hash) capability=\(record.capability.rawValue)",
                "\(hostField) \(record.keyType) \(record.keyBlob.base64EncodedString())",
            ])
        }

        // Blank line first: ssh treats `#` as a comment, but a trailing-NEWLINE-
        // only file is also accepted, and keeping the marker on its own line
        // avoids any risk of concatenating it with a key line.
        return ([emptyFileMarker] + lines + [""]).joined(separator: "\n")
    }

    /// The `known_hosts` host field for a host/port pair.
    ///
    /// `[host]:port` for any non-22 port, plain `host` for 22. Matching ssh(1):
    /// `UserKnownHostsFile` entries for a non-default port must carry the bracket.
    public static func hostField(host: String, port: UInt16) -> String {
        let normalized = host.trimmingCharacters(in: .whitespaces)
        guard port != 22 else { return normalized }
        return "[\(normalized)]:\(port)"
    }

    /// Parse a rendered file back into records, for round-trip verification.
    ///
    /// Not used by production; ssh is the consumer. It exists so a test can prove
    /// the renderer's output is stable under a round trip rather than only
    /// checking the string it produced.
    public static func parse(_ text: String) -> [ParsedEntry] {
        var entries: [ParsedEntry] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard fields.count >= 3 else { continue }
            guard let blob = Data(base64Encoded: fields[2]) else { continue }
            entries.append(
                ParsedEntry(hostField: fields[0], keyType: fields[1], blob: blob)
            )
        }
        return entries
    }

    public struct ParsedEntry: Sendable, Equatable {
        public let hostField: String
        public let keyType: String
        public let blob: Data
    }
}