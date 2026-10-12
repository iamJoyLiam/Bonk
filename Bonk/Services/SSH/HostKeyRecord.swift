//
//  HostKeyRecord.swift
//  Bonk
//
//  The canonical host-key trust record.
//
//  ## Why this is a new type
//
//  `SSHHostFingerprint` is `{ let hash: String }` — a bare SHA-256, which is
//  deliberately one-way. OpenSSH cannot be told "trust this digest"; it needs
//  the actual public key in a `known_hosts` line. So key material cannot live
//  inside a fingerprint, and extending `SSHHostFingerprint` to carry it would
//  make a type that is used for comparison start carrying data it cannot be
//  compared on.
//
//  ## Why the capability exists
//
//  `NIOSSHPublicKey` cannot represent an RSA host key at all — its `BackingKey`
//  covers ed25519, ecdsa-p256/384/521, custom and certified, and the NIOSSH
//  sources contain no RSA. A record therefore needs to record *where* it is
//  usable. `openSSHOnly` is provenance, not a second trust store: the same
//  canonical record is authoritative either way, and no path may fall back to a
//  separate OpenSSH trust store.
//

import Crypto
import Foundation

/// Provenance of a record's key material.
public enum HostKeyCapability: String, Codable, Sendable, Equatable {
    /// The native (Citadel) transport can represent this key, so both transports
    /// may use the record.
    case nativeAndOpenSSH
    /// Only the OpenSSH transport can represent this key — RSA today. The record
    /// is still canonical and still authoritative.
    case openSSHOnly
}

/// One host's trusted key. The unit of trust in the canonical store.
public struct HostKeyRecord: Codable, Sendable, Equatable {
    public let fingerprint: SSHHostFingerprint
    /// SSH **wire format** of the key (`ssh-ed25519`, `ecdsa-sha2-nistp256`,
    /// `ssh-rsa`). Not a signature algorithm — see `HostKeySignatureAlgorithms`.
    public let keyType: String
    /// Raw SSH public-key blob. Base64 only when serialized to `known_hosts`.
    public let keyBlob: Data
    public let capability: HostKeyCapability

    public init(
        fingerprint: SSHHostFingerprint,
        keyType: String,
        keyBlob: Data,
        capability: HostKeyCapability
    ) {
        self.fingerprint = fingerprint
        self.keyType = keyType
        self.keyBlob = keyBlob
        self.capability = capability
    }
}

/// What a lookup found. Four states, not a nullable fingerprint.
///
/// The distinction that matters is `legacyFingerprintOnly` versus `absent`: a
/// host pinned before key material was stored has real trust, and treating it as
/// unknown would let a migration handshake re-establish trust from scratch.
public enum HostKeyLookup: Sendable, Equatable {
    case absent
    case legacyFingerprintOnly(SSHHostFingerprint)
    case complete(HostKeyRecord)
    /// The stored record failed validation. Fail closed: never a usable trust.
    case invalidOrCorrupt(reason: String)

    public var record: HostKeyRecord? {
        if case let .complete(record) = self { return record }
        return nil
    }

    /// Whether this host has *any* established trust. A corrupt record is not
    /// trust, and a legacy fingerprint is trust.
    public var hasEstablishedTrust: Bool {
        switch self {
        case .absent, .invalidOrCorrupt: false
        case .legacyFingerprintOnly, .complete: true
        }
    }
}

/// Result of `recordIfAbsentOrMatching`.
public enum HostKeyCASOutcome: String, Sendable, Equatable {
    /// No prior record; the candidate is now trusted.
    case inserted
    /// An identical complete record already existed.
    case alreadyMatching
    /// A different key is already trusted. **Never overwrite.**
    case conflict
    /// The commit could not be made durable. Trust must NOT be treated as
    /// established.
    case persistenceFailure
}

/// Result of `backfillKeyMaterial`.
public enum HostKeyBackfillOutcome: String, Sendable, Equatable {
    case backfilled
    /// The record was already complete and consistent; nothing to do.
    case alreadyComplete
    case conflict
    case persistenceFailure
}

// MARK: - Blob parsing and validation

/// Reads an SSH public-key blob, and derives everything that must agree with it.
public enum HostKeyBlob {
    public struct Parsed: Sendable, Equatable {
        public let keyType: String
        /// The digest of the whole blob, which is what both Bonk and OpenSSH mean
        /// by an `SHA256:` fingerprint.
        public let fingerprint: SSHHostFingerprint
    }

    /// Wire format is `<uint32 length><key type><key material>`.
    ///
    /// Parsing it here is what lets a stored record be re-validated: the type
    /// and the fingerprint are both recomputed from the bytes, so a record whose
    /// fields disagree with its own key material is detectable rather than
    /// trusted.
    public static func parse(_ blob: Data) -> Parsed? {
        var cursor = 0

        func readUInt32() -> UInt32? {
            guard cursor + 4 <= blob.count else { return nil }
            var value: UInt32 = 0
            for offset in cursor ..< cursor + 4 {
                value = (value << 8) | UInt32(blob[blob.startIndex + offset])
            }
            cursor += 4
            return value
        }

        guard let length = readUInt32() else { return nil }
        // A key type is a short identifier; anything huge means a corrupt blob.
        guard length > 0, length < 128, cursor + Int(length) <= blob.count else { return nil }
        let typeBytes = blob[blob.startIndex + cursor ..< blob.startIndex + cursor + Int(length)]
        guard let keyType = String(data: Data(typeBytes), encoding: .utf8) else { return nil }

        return Parsed(keyType: keyType, fingerprint: fingerprint(of: blob))
    }

    /// The same computation `HostKeyValidator` performs, and the same one ssh
    /// prints: base64(SHA256(blob)), `=` stripped, prefixed `SHA256:`.
    public static func fingerprint(of blob: Data) -> SSHHostFingerprint {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return SSHHostFingerprint(hash: "SHA256:\(digest)")
    }

    /// A record is only usable if its fields agree with its own key material.
    ///
    /// Re-deriving both is the point: a record edited or truncated in storage
    /// fails closed here instead of being handed to a connection.
    public static func validate(_ record: HostKeyRecord) -> String? {
        guard let parsed = parse(record.keyBlob) else {
            return "keyBlob is not a parseable SSH public key"
        }
        guard parsed.keyType == record.keyType else {
            return "keyType '\(record.keyType)' does not match the blob's '\(parsed.keyType)'"
        }
        guard parsed.fingerprint == record.fingerprint else {
            return "fingerprint does not match the key material"
        }
        return nil
    }

    /// The signature algorithms permitted for a given **wire format**.
    ///
    /// `HostKeyAlgorithms` names signature algorithms, and a key's wire format is
    /// not always one of them. `ssh-rsa` is the wire format for an RSA key;
    /// RFC 8332 lets that same key be used with `rsa-sha2-256` and `rsa-sha2-512`,
    /// and OpenSSH lists `rsa-sha2-*` as signature algorithms only — there is no
    /// `rsa-sha2-*` wire format. Copying `keyType` into `HostKeyAlgorithms` is
    /// therefore wrong, and would also forbid the modern RSA signatures.
    ///
    /// SHA-1 signatures are listed last and only for a server that offers
    /// nothing else; callers should treat their use as an explicit compatibility
    /// exception rather than a default.
    public static func signatureAlgorithms(forKeyType keyType: String) -> [String] {
        switch keyType {
        case "ssh-ed25519":
            return ["ssh-ed25519"]
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return [keyType]
        case "ssh-rsa":
            return ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"]
        default:
            // Unknown format: permit exactly what the blob declares, and nothing
            // else. Guessing here would widen the accepted key set.
            return [keyType]
        }
    }
}