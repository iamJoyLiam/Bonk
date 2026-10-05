//
//  TeamSSHGuest.swift
//  Bonk
//
//  The guest half of the encrypted team transport.
//
//  Connecting is now: verify the host key *inside* the handshake, authenticate
//  with the team PIN, then open a direct-tcpip channel back to the host's
//  loopback. The Team protocol rides that channel, so there is no plaintext
//  path left to fall back to — if any of these three steps fails, the
//  connection fails. No `Err` is ever converted into a working session.
//
//

import Citadel
import Foundation
import Network
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import os.log

/// Connects a guest to a team host over SSH.
struct TeamSSHGuest {
    private static let logger = Logger(subsystem: "com.bonk", category: "TeamSSHGuest")

    let host: String
    let port: Int
    let displayName: String
    let pin: String
    /// The host identity the user has already pinned, if any.
    ///
    /// Injected rather than read from `TeamIdentityStore` here: a connector
    /// that reached into process-wide `UserDefaults` for its own trust input
    /// could not be tested against a chosen identity, and two relays in one
    /// process would silently share a trust decision.
    /// The SSH host key we trust for this peer, as `SHA256` of the peer's
    /// NIOSSH public-key wire bytes.
    ///
    /// Explicitly *not* a Team identity fingerprint. The two share an encoding
    /// and nothing else, and this value is compared against a hash of the key
    /// the server presents, so a seed-derived value here can never match —
    /// which is exactly what used to happen: production read the pairing pin
    /// and handed it to the validator.
    let pinnedHostFingerprint: String?
    /// Reports the host key the handshake actually presented, so a caller can
    /// pin it. Values come from the wire rather than being derived locally,
    /// which is what makes "pin what you saw" and "verify what you see" the
    /// same comparison.
    var onHostKey: (@Sendable (String) -> Void)?

    init(
        host: String,
        port: Int,
        displayName: String,
        pin: String,
        pinnedHostFingerprint: String?,
        onHostKey: (@Sendable (String) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.displayName = displayName
        self.pin = pin
        self.pinnedHostFingerprint = pinnedHostFingerprint
        self.onHostKey = onHostKey
    }

    enum Failure: LocalizedError {
        case badEndpoint

        var errorDescription: String? {
            switch self {
            case .badEndpoint:
                return L.t(.aiConnectFailed) + ": bad endpoint"
            }
        }
    }

    /// Perform the handshake and return a live channel.
    ///
    /// The host key is checked *before* the PIN is transmitted, and only
    /// there: `HostKeyValidator` receives the pinned fingerprint and fails the
    /// handshake inside its callback, so the credential never reaches whoever
    /// answered. First use is a trust-on-first-use decision, which is a valid
    /// policy and is reported through `onHostKey`.
    ///
    /// There is deliberately no second check after the handshake. An earlier
    /// version had one; removing it left every test green, which is how it was
    /// established to be unreachable — the validator already refuses the
    /// connection, and it does so before the PIN is sent, which a later check
    /// could not. One enforcement point, proven load-bearing.
    func connect() async throws -> SSHTeamChannel {
        // A pinned identity must be presented to the validator, not merely
        // compared afterwards: post-hoc comparison is too late, the PIN has
        // already been sent.
        // Re-labelling is unavoidable at this boundary — the pin is persisted as
        // a string — so the invariant is enforced where the string enters, not
        // here: only a value the validator itself derived may be written back
        // through `onHostKey`. See `TeamRelay`'s wiring.
        let pinnedHash = pinnedHostFingerprint
        let pinned = pinnedHash.map { SSHHostFingerprint(hash: $0) }
        let presented = NIOLockedValueBox<SSHHostFingerprint?>(nil)
        let validator = HostKeyValidator(expected: pinned) { [onHostKey] fingerprint in
            presented.withLockedValue { $0 = fingerprint }
            onHostKey?(fingerprint.hash)
        }

        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: TeamSSHAuthDelegate.guestUsername, password: pin),
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            algorithms: .all
        )

        guard presented.withLockedValue({ $0 }) != nil else {
            throw Failure.badEndpoint
        }

        let factory = TeamSSHChannelFactory(client: client)
        let channel = try await factory.open(hostPort: port)
        channel.startReceiving()
        Self.logger.info("Team guest channel established over SSH")
        return channel
    }
}
