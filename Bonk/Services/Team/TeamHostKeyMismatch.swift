//
//  TeamHostKeyMismatch.swift
//  Bonk
//
//  Naming a refused host key so the user can be shown the two fingerprints and
//  given the one recovery that exists.
//
//  Why this is a separate type: a failed connect and a *changed host key* are
//  different facts. Only the second has an action behind it — dropping the pin
//  and learning whatever is there now. Reporting both as "connection failed"
//  leaves a user with a legitimate rotated key permanently locked out, because
//  the pin is invisible to them and every retry fails at the same point.
//

import Foundation

/// The two values a host-key refusal produced.
struct TeamHostKeyMismatch: Equatable, Sendable {
    /// What we trusted, from the pin.
    let pinned: String
    /// What the server actually presented, as the validator hashed it.
    let presented: String
}

/// Decides whether a failed connection was a changed-host-key refusal.
///
/// Pure so the distinction is testable on its own, and matched on the error
/// *type* rather than its text: the message is a localized string in
/// `SSHServiceError.errorDescription`, and keying on it would mean a
/// re-worded sentence silently removes the user's only way back.
enum TeamHostKeyMismatchClassifier {
    static func classify(_ error: Error) -> TeamHostKeyMismatch? {
        guard let sshError = error as? SSHServiceError,
              case let .hostKeyMismatch(expected, received) = sshError
        else { return nil }
        return TeamHostKeyMismatch(pinned: expected, presented: received)
    }
}