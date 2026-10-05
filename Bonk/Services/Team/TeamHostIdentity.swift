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

/// `UserDefaults` is thread-safe but not `Sendable`, so nothing here can cross
/// an isolation boundary while holding one directly. The box exists only to
/// carry the reference; it adds no state of its own.
private struct DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults
}

/// Per-install storage for the hosting identity and the trust decisions a guest
/// makes about a host, so all three survive restarts (a rotating identity would
/// raise a false "host changed" alarm on every launch).
///
/// Injected rather than reading `UserDefaults.standard` inline, for the same
/// reason `TeamSSHGuest` takes its pin as a parameter: a trust decision that
/// reaches into process-wide storage for its own input cannot be tested against
/// a chosen trust state, and two relays in one process cannot hold independent
/// opinions about their hosts. Follows `TeamHostKeyStore`.
struct TeamIdentityStore: @unchecked Sendable {
    private static let hostSeedKey = "team.hostIdentity.seed"
    /// Unchanged key: this slot has always held the *identity* fingerprint.
    /// It was only ever wrong because a reader treated it as an SSH host key.
    private static let pinnedTeamIdentityKey = "team.pinnedHostFingerprint"
    private static let pinnedSSHHostKey = "team.pinnedSSHHostKeyFingerprint"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// This machine's identity as a host, created on first use.
    func hostIdentity() -> TeamHostIdentity {
        if let seed = defaults.string(forKey: Self.hostSeedKey), !seed.isEmpty {
            return TeamHostIdentity(fingerprint: TeamHostIdentity.fingerprint(forSeed: seed), seed: seed)
        }
        let identity = TeamHostIdentity.generate()
        defaults.set(identity.seed, forKey: Self.hostSeedKey)
        return identity
    }

    /// Regenerate the hosting identity, e.g. after the user asks to be
    /// unreachable by previous pairings.
    func resetHostIdentity() -> TeamHostIdentity {
        let identity = TeamHostIdentity.generate()
        defaults.set(identity.seed, forKey: Self.hostSeedKey)
        return identity
    }

    // MARK: - Two trust surfaces, two slots

    /// The Team identity we paired with: `SHA256` of that host's identity seed.
    ///
    /// Read by `PairingGate` and written from `pairingAccepted`. This is *not*
    /// the SSH host key, and the two used to share one slot — which let a
    /// seed-derived value be handed to the host-key validator as though it were
    /// a public-key fingerprint. They are separate objects and are now stored
    /// separately.
    func pinnedTeamIdentityFingerprint() -> String? {
        defaults.string(forKey: Self.pinnedTeamIdentityKey)
    }

    /// The SSH host key we paired with: `SHA256` of the peer's NIOSSH
    /// public-key wire bytes, as reported by `HostKeyValidator`.
    ///
    /// This is the value the transport layer must compare against, and the only
    /// value that may be wrapped in an `SSHHostFingerprint`.
    func pinnedSSHHostKeyFingerprint() -> String? {
        defaults.string(forKey: Self.pinnedSSHHostKey)
    }

    func pinTeamIdentityFingerprint(_ fingerprint: String) {
        defaults.set(fingerprint, forKey: Self.pinnedTeamIdentityKey)
    }

    /// Record a host key the handshake just accepted.
    ///
    /// Only ever called with a value the validator derived from the key the
    /// server actually presented — never with a Team identity fingerprint.
    func pinSSHHostKeyFingerprint(_ fingerprint: String) {
        defaults.set(fingerprint, forKey: Self.pinnedSSHHostKey)
    }

    /// The one closure that records a learned host key.
    ///
    /// Production passes this straight to `TeamSSHGuest.onHostKey`, and the
    /// tests take theirs from here too. That sharing is the point: a test that
    /// built its own closure would still pass with the production wiring
    /// deleted, which is precisely the failure this surface keeps producing.
    func pinLearnedSSHHostKey() -> @Sendable (String) -> Void {
        let box = DefaultsBox(defaults: defaults)
        return { fingerprint in
            box.defaults.set(fingerprint, forKey: Self.pinnedSSHHostKey)
        }
    }

    /// Drop the pinned SSH host key so the next connection learns again.
    ///
    /// Needed because a legitimate host key rotation would otherwise be
    /// indistinguishable from an impostor, leaving the user with no way back:
    /// every connect would fail before the PIN, with nothing on screen to act.
    ///
    /// Only the SSH slot: the identity pin is a different trust decision, and
    /// forgetting one must not silently discard the other.
    func forgetPinnedHost() {
        defaults.removeObject(forKey: Self.pinnedSSHHostKey)
    }
}
