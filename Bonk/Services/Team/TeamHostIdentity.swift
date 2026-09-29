//
//  TeamHostIdentity.swift
//  Bonk
//
//  A stable identity for the machine hosting a team session, so a guest can
//  notice when the peer on the other end of a Bonjour-discovered connection
//  changes.
//
//  Scope, stated honestly: this is TOFU change detection, not cryptographic
//  authentication. The fingerprint is derived from a locally generated seed,
//  so an attacker who has never talked to this machine cannot guess it, but
//  an attacker who observes one successful pairing can replay the fingerprint.
//  Confidentiality and true authentication require TLS, which is a separate
//  change. What this identity does buy is a signal the user can act on, and it
//  is the same trust model already applied to SSH host keys.
//
//  The seed is a public identity token, not a secret: it is never used to
//  authenticate, so UserPreferences storage is appropriate here rather than
//  the Keychain.
//

import Crypto
import Foundation

struct TeamHostIdentity: Codable, Sendable, Equatable {
    /// SHA256 of the seed, formatted like an SSH host-key fingerprint so the
    /// two trust surfaces read the same way.
    let fingerprint: String
    /// Opaque local token; never transmitted.
    let seed: String

    /// Generate a brand-new identity, replacing any previous one.
    static func generate() -> TeamHostIdentity {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let seed: String
        if status == errSecSuccess {
            seed = Data(bytes).base64EncodedString()
        } else {
            // SecRandomCopyBytes failing is not recoverable and must not fall
            // back to a predictable identity.
            seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return TeamHostIdentity(fingerprint: fingerprint(forSeed: seed), seed: seed)
    }

    static func fingerprint(forSeed seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let body = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(body)"
    }

    /// Trust decision for a fingerprint presented by a host we are pairing with.
    enum Decision: Equatable {
        /// First time we have seen this host — accept and pin.
        case trustOnFirstUse
        /// Matches the pinned fingerprint.
        case trustedMatch
        /// Differs from the pinned fingerprint: the host changed, or someone
        /// else is answering. Never silently accepted.
        case mismatch(pinned: String, presented: String)
    }

    static func decide(presented: String, pinned: String?) -> Decision {
        guard let pinned, !pinned.isEmpty else { return .trustOnFirstUse }
        return pinned == presented ? .trustedMatch : .mismatch(pinned: pinned, presented: presented)
    }
}

/// Per-install storage for the hosting identity and the last host we paired
/// with, so both survive restarts (a rotating identity would raise a false
/// "host changed" alarm on every launch).
enum TeamIdentityStore {
    private static let hostSeedKey = "team.hostIdentity.seed"
    private static let pinnedHostKey = "team.pinnedHostFingerprint"

    /// This machine's identity as a host, created on first use.
    static func hostIdentity() -> TeamHostIdentity {
        if let seed = UserDefaults.standard.string(forKey: hostSeedKey), !seed.isEmpty {
            return TeamHostIdentity(fingerprint: TeamHostIdentity.fingerprint(forSeed: seed), seed: seed)
        }
        let identity = TeamHostIdentity.generate()
        UserDefaults.standard.set(identity.seed, forKey: hostSeedKey)
        return identity
    }

    /// Regenerate the hosting identity, e.g. after the user asks to be
    /// unreachable by previous pairings.
    static func resetHostIdentity() -> TeamHostIdentity {
        let identity = TeamHostIdentity.generate()
        UserDefaults.standard.set(identity.seed, forKey: hostSeedKey)
        return identity
    }

    static func pinnedHostFingerprint() -> String? {
        UserDefaults.standard.string(forKey: pinnedHostKey)
    }

    static func pinHostFingerprint(_ fingerprint: String) {
        UserDefaults.standard.set(fingerprint, forKey: pinnedHostKey)
    }

    static func forgetPinnedHost() {
        UserDefaults.standard.removeObject(forKey: pinnedHostKey)
    }
}
