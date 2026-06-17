//
//  HostKeyValidator.swift
//  Bonk
//
//  Host key validation for SSH connections.
//

import Foundation
import NIOCore
import NIOSSH

/// Host key validator for SSH connections.
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let onHostKey: @Sendable (NIOSSHPublicKey) -> Void

    init(onHostKey: @escaping @Sendable (NIOSSHPublicKey) -> Void) {
        self.onHostKey = onHostKey
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        onHostKey(hostKey)
        validationCompletePromise.succeed(())
    }
}
