//
//  SecureEnclaveAuthDelegate.swift
//  Bonk
//
//  NIOSSH client authentication delegate for Secure Enclave keys.
//

import Foundation
import NIOCore
@preconcurrency import NIOSSH
import os

/// Authentication delegate for Secure Enclave-backed SSH keys.
/// This handles the SSH publickey authentication flow using Secure Enclave.
final class SecureEnclaveAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let privateKey: SecureEnclavePrivateKey

    init(username: String, privateKey: SecureEnclavePrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Check if server supports publickey authentication
        guard availableMethods.contains(.publicKey) else {
            Log.ssh.warning("Server does not support publickey authentication")
            nextChallengePromise.fail(SSHServiceError.connectionFailed(
                "Server does not support publickey authentication"
            ))
            return
        }

        // Create the authentication offer with our Secure Enclave key
        let offer = NIOSSHUserAuthenticationOffer.Offer.privateKey(
            .init(privateKey: NIOSSHPrivateKey(custom: privateKey))
        )

        let authOffer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: offer
        )

        nextChallengePromise.succeed(authOffer)
    }
}
