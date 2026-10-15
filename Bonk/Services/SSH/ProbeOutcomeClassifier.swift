//
//  ProbeOutcomeClassifier.swift
//  Bonk
//
//  Classifies the result of a credential-free host-key probe.
//
//  ## Why this exists
//
//  `ssh` has no "host key verified" exit code. It exits non-zero both when the
//  key is rejected and when authentication is refused, so exit status alone
//  cannot separate them. Only the middle of three outcomes may authorise a
//  trust write; the other two must fail closed.
//
//  ## Why the positive marker is required
//
//  `Permission denied` is not evidence. ssh prints it for a host whose key was
//  never verified — under `accept-new`, ssh adds the key without comparing it
//  and then refuses authentication, producing exactly that line. Treating an
//  auth refusal as "key accepted" is the silent trust downgrade this classifier
//  exists to prevent.
//
//  ssh's own `is known and matches the ... host key` / `Found key in <file>:1`
//  appears only on the accept path, so requiring it is what makes the middle
//  outcome meaningful.
//

import Foundation

/// The three outcomes a credential-free probe must distinguish.
///
/// Ordering is the whole design: only `keyAcceptedAuthenticationRefused` may
/// authorise a trust write. Everything else fails closed.
public enum ProbeOutcome: String, Sendable, Equatable {
    /// The server presented a key that is not the one we recorded.
    case keyRejected
    /// ssh positively verified the key against our trust file, then refused
    /// authentication because no credential was configured.
    case keyAcceptedAuthenticationRefused
    /// Nothing was proven: refused, timed out, or insufficient evidence.
    case inconclusive
}

/// Classifies a credential-free probe. Pure: no process, no filesystem.
public enum ProbeOutcomeClassifier {
    /// ssh's positive confirmation that the presented key matched an entry in
    /// our trust file. Emitted only on the accept path; never on reject.
    private static let knownAndMatches = "is known and matches the"
    private static let foundKeyIn = "Found key in"

    /// Genuine rejection markers. `parse error in hostkeys file` is listed so a
    /// corrupt trust file is recognised as *not* a server-side rejection — it
    /// ends on the same final line as a real mismatch, and confusing the two
    /// would let a malformed trust file pass as a correctly-rejected key.
    private static let trustFileUnusable = [
        "parse error in hostkeys file",
        "hostkeys file is not readable",
    ]
    private static let verificationFailed = "Host key verification failed"

    /// Authentication completed to the point of refusing us, which — combined
    /// with the positive match above — means the key was good.
    private static let authRefused = [
        "Permission denied",
        "No more authentication methods to try",
    ]

    /// Connections that never reached a host-key decision.
    private static let transportFailures = [
        "Connection refused",
        "Connection timed out",
        "Operation timed out",
        "No route to host",
        "connect to host",
        "kex_exchange_identification",
        "Connection reset",
    ]

    public static func classify(status: Int32, timedOut: Bool, stderr: String) -> ProbeOutcome {
        if timedOut { return .inconclusive }

        // A trust file we cannot read proves nothing about the server, and it
        // surfaces with the same final line as a real mismatch. Checked first so
        // it can never be mistaken for one.
        if trustFileUnusable.contains(where: { stderr.contains($0) }) {
            return .inconclusive
        }

        let positivelyMatched = stderr.contains(knownAndMatches) || stderr.contains(foundKeyIn)
        if positivelyMatched {
            // ssh will not print either marker unless the key matched, so this is
            // the only branch that may authorise a trust write.
            return .keyAcceptedAuthenticationRefused
        }

        if stderr.contains(verificationFailed) { return .keyRejected }

        if authRefused.contains(where: { stderr.contains($0) }) {
            // Refused authentication without a positive host-key confirmation.
            // Treating this as "accepted" is the failure mode this classifier
            // exists to prevent.
            return .inconclusive
        }

        if transportFailures.contains(where: { stderr.contains($0) }) {
            return .inconclusive
        }

        return .inconclusive
    }

    /// Whether the probe actually offered a credential.
    ///
    /// Checked against ssh's own log rather than inferred from the flag set,
    /// because flags can only be verified by what ssh reports doing. Note that
    /// `Authentications that can continue: password` is the *server* advertising
    /// what it accepts — it is not an offer, and treating it as one would report
    /// a false positive on every correctly-configured probe.
    public static func offeredCredentials(stderr: String) -> Bool {
        let offeringMarkers = [
            "Offering public key",
            "Server accepts key",
            "send packet: type 50",
            "Trying private key",
            "send packet: type 30",
        ]
        return offeringMarkers.contains { stderr.contains($0) }
    }

    /// Whether ssh *read* any identity material, whether or not it offered it.
    ///
    /// A stronger property than `offeredCredentials`. With only the method flags
    /// set, ssh logged `loaded pubkey from /Users/…/.ssh/id_ed25519` — the offer
    /// was suppressed, but the file was still read. Nothing was sent, yet the
    /// probe had touched the user's identity material, and a claim of complete
    /// identity isolation would have been false.
    ///
    /// `IdentityAgent=none` and `IdentityFile=none` are what remove these lines;
    /// the method flags alone do not.
    public static func touchedIdentityMaterial(stderr: String) -> Bool {
        let loadingMarkers = [
            "identity file",
            "loaded pubkey from",
            "no pubkey loaded from",
            "no identity pubkey loaded from",
            "will attempt agent",
            "agent_auth",
        ]
        return loadingMarkers.contains { stderr.contains($0) }
    }
}