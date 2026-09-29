//
//  TeamHostKeyStore.swift
//  Bonk
//
//  Persistence for the relay's SSH host key.
//
//  Trust boundary, stated plainly: this stores a **long-term private key** in
//  UserDefaults, which is not a secret store. The Keychain is the correct home
//  for key material, but this project does not have Keychain entitlements
//  wired into the target, and routing this through provisioning profiles /
//  Developer Portal is the dependency the team transport change was meant to
//  avoid. Migrating to the Keychain is a tracked follow-up.
//
//  What the key is and is not:
//  - It is the machine's SSH *identity*, presented to guests for the host-key
//    TOFU check. It never authenticates anyone and is never transmitted
//    except as part of a public host-key exchange.
//  - Because guests pin its fingerprint, replacing it is visible: every
//    paired guest reports a changed host identity rather than trusting
//    whatever answers next.
//

import Crypto
import Foundation
import NIOCore
import NIOSSH
import os.log

/// Generates and persists the relay's SSH host key.
struct TeamHostKeyStore {
    private static let storageKey = "com.bonk.team.sshHostKey"
    private static let logger = Logger(subsystem: "com.bonk", category: "TeamHostKey")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted host key, generating one on first use.
    ///
    /// Never rotates implicitly: a new key would make every paired guest see a
    /// changed host identity, which is a security signal, not noise to suppress.
    func loadOrCreateHostKey() -> NIOSSHPrivateKey? {
        let seed: Data
        if let stored = defaults.data(forKey: Self.storageKey) {
            if let key = Self.key(fromSeed: stored) { return key }
            Self.logger.warning("Stored team host key is unusable; regenerating")
            seed = Curve25519.Signing.PrivateKey().rawRepresentation
        } else {
            seed = Curve25519.Signing.PrivateKey().rawRepresentation
        }
        defaults.set(seed, forKey: Self.storageKey)
        return Self.key(fromSeed: seed)
    }

    /// Delete the stored key. Every paired guest will report a changed host
    /// identity afterwards, so only for an explicit user action.
    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Seed the store with a known key, replacing whatever was there.
    ///
    /// Production never calls this — the key is generated on first use. It
    /// exists so a test can give two hosts *provably* different identities,
    /// which a shared default store cannot do.
    func injectSeed(_ seed: Data) {
        defaults.set(seed, forKey: Self.storageKey)
    }

    /// The raw 32-byte Curve25519 seed is the unit of persistence. The key is
    /// generated here, so its raw form is enough — no OpenSSH envelope, and no
    /// extra package dependency for one.
    private static func key(fromSeed seed: Data) -> NIOSSHPrivateKey? {
        guard seed.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        else { return nil }
        return NIOSSHPrivateKey(ed25519Key: key)
    }
}
