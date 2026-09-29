//
//  TeamSSHAuthDelegate.swift
//  Bonk
//
//  SSH user authentication for the team relay: the team PIN is the credential.
//  This is a thin adapter from NIOSSH's callback shape to
//  `TeamPINAuthenticator`, kept separate so the rate-limit policy stays
//  testable without a socket (see TeamPINAuthenticatorTests).
//

import Foundation
import NIOCore
import NIOSSH
import os.log

/// Bridges NIOSSH server user-authentication to `TeamPINAuthenticator`.
final class TeamSSHAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    private let authenticator: TeamPINAuthenticator
    private let expectedPin: @Sendable () -> String?
    private let logger = Logger(subsystem: "com.bonk", category: "TeamAuth")

    /// The username every guest presents.
    ///
    /// It is *not* an identity: SSH usernames are client-supplied, so an
    /// attacker chooses it freely. It exists only so the guest has a username
    /// field, and `TeamPINAuthenticator` does not treat it as an identity —
    /// see its global budget for why per-peer keying is not load-bearing.
    static let guestUsername = "bonk-team-guest"

    init(authenticator: TeamPINAuthenticator, expectedPin: @escaping @Sendable () -> String?) {
        self.authenticator = authenticator
        self.expectedPin = expectedPin
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        [.password]
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard case let .password(presented) = request.request else {
            // Only the PIN is accepted. A public-key or none request is
            // refused outright rather than partially satisfied, so a peer
            // cannot enumerate which methods this relay supports.
            responsePromise.succeed(.failure)
            return
        }
        guard let pin = expectedPin(), !pin.isEmpty else {
            logger.error("Team relay has no PIN; refusing authentication")
            responsePromise.succeed(.failure)
            return
        }

        let peer = request.username.isEmpty ? "unknown" : request.username
        switch authenticator.evaluate(
            peer: peer,
            presentedPin: presented.password,
            expectedPin: pin
        ) {
        case .accept:
            logger.info("Team peer authenticated")
            responsePromise.succeed(.success)
        case .reject:
            responsePromise.succeed(.failure)
        case let .lockedOut(retryAfter):
            logger.warning("Team peer locked out for \(Int(retryAfter))s after repeated failures")
            responsePromise.succeed(.failure)
        }
    }
}
