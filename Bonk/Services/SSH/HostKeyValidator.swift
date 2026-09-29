//
//  HostKeyValidator.swift
//  Bonk
//
//  Host key validation for SSH connections.
//

import Crypto
import Foundation
import NIOCore
import NIOSSH
import os.log

/// Host key validator for SSH connections.
///
/// Security invariant: the trust decision happens HERE, inside the
/// handshake callback, BEFORE any authentication material is sent.
/// Callers snapshot the known fingerprint (TOFU store) before
/// `SSHClient.connect` and inject it as `expected`:
/// - known host + mismatch → promise fails → handshake aborts,
///   credentials never leave the client;
/// - known host + match, or first-seen (expected == nil) → record
///   the fingerprint via `onHostKey` and let the handshake proceed.
/// First-seen persistence stays with the caller (post-connect save).
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expected: SSHHostFingerprint?
    private let onHostKey: @Sendable (SSHHostFingerprint) -> Void

    init(expected: SSHHostFingerprint?, onHostKey: @escaping @Sendable (SSHHostFingerprint) -> Void) {
        self.expected = expected
        self.onHostKey = onHostKey
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let bytes = Data(buffer.readableBytesView)
        let digest = SHA256.hash(data: bytes)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fingerprint = SSHHostFingerprint(hash: "SHA256:\(b64)")
        if let expected, expected.hash != fingerprint.hash {
            Log.ssh.error("Host key mismatch before auth, aborting handshake")
            validationCompletePromise.fail(
                SSHServiceError.hostKeyMismatch(expected: expected.hash, received: fingerprint.hash)
            )
            return
        }
        onHostKey(fingerprint)
        validationCompletePromise.succeed(())
    }
}
