//
//  LegacyHostKeyMigrator.swift
//  Bonk
//
//  Imports the pre-canonical trust state (`com.bonk.hostKeys`) into the canonical
//  host-key store.
//
//  ## What is being migrated
//
//  `PersistentHostKeyStore` kept `host:port -> SHA-256 fingerprint` in
//  `UserDefaults`. That is a real trust decision, taken on first contact and
//  never revisited. The canonical store keeps the same pin *plus* the public key
//  material needed to verify a connection without a probe. So the legacy data is
//  evidence, not debris: discarding it would silently re-authorise first contact
//  for every host the user had already pinned, which is precisely the downgrade
//  AUDIT-FIND-001 exists to end.
//
//  ## The three rules
//
//  1. **Additive.** Legacy entries are never deleted. A rollback must not lose
//     trust that predates the canonical store.
//  2. **Never displace.** A bare fingerprint must not overwrite a stored record.
//     The canonical store holds strictly more information, so a collision means
//     the canonical value wins and the legacy value is reported, not applied.
//  3. **Conflict is visible and inert.** Where the legacy pin disagrees with an
//     existing canonical record, the migration does not resolve it — the store
//     and the legacy data are both left exactly as they were, and the conflict is
//     returned to the caller.
//
//  Rule 3 is the one that needs saying twice. A migration is the one place in
//  this subsystem where a disagreement between two trust stores could be
//  silently settled in favour of whichever ran last. It must not be. Resolution
//  of a genuine conflict is a user decision — and in practice it surfaces later,
//  at connection time, as the resolver's `legacyPinMismatch` refusing to
//  establish trust against a pin that no longer matches.
//
//  ## Why the legacy reader is injected
//
//  `UserDefaults.standard` is the user's real defaults domain. A migration
//  implementation that hardcoded it could not be tested without either touching
//  the user's data or writing a parallel implementation — and the second is how
//  AUDIT-DEF-003 happened. The reader is a protocol requirement, so a test must
//  supply an isolated source.
//

import Foundation

/// Supplies the legacy `host:port -> fingerprint` map.
///
/// A protocol rather than a parameter of type `[String: SSHHostFingerprint]`
/// because the *source* is the thing that must be swappable: a dictionary
/// parameter would still have to be filled from `UserDefaults.standard`
/// somewhere, and that somewhere is what writes to the user's data.
public protocol LegacyHostKeySource: Sendable {
    func legacyFingerprints() -> [String: SSHHostFingerprint]
}

/// Reads `com.bonk.hostKeys` from a `UserDefaults` domain.
///
/// The domain is a parameter, not hardcoded. Production passes `.standard`; a
/// test passes its own suite, so the user's defaults are never read or written
/// by a test.
public struct UserDefaultsLegacyHostKeySource: LegacyHostKeySource {
    public static let defaultsKey = "com.bonk.hostKeys"

    /// `UserDefaults` is not `Sendable`. Safe here for the same reason the rest of
    /// this subsystem treats it that way: the instance is fixed at construction,
    /// never re-pointed, and `UserDefaults` documents its own accessors as
    /// thread-safe.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func legacyFingerprints() -> [String: SSHHostFingerprint] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let map = try? JSONDecoder().decode([String: SSHHostFingerprint].self, from: data)
        else {
            return [:]
        }
        return map
    }
}

/// One host's migration outcome.
public enum LegacyMigrationOutcome: Equatable, Sendable {
    /// No trust state existed for this host; nothing to carry over.
    case nothingToMigrate
    /// The pin was carried into the canonical store's legacy table.
    case imported
    /// The canonical store already held a matching pin; nothing to do.
    case alreadyPresent
    /// A canonical record exists and disagrees with the legacy pin.
    ///
    /// Neither side was modified. This is the case that must never be resolved
    /// silently.
    case conflict(canonical: SSHHostFingerprint, legacy: SSHHostFingerprint)
    /// The legacy key was not parseable as `host:port`.
    case malformedKey(String)
}

/// The result of a whole migration pass.
public struct LegacyMigrationReport: Equatable, Sendable {
    public var outcomes: [String: LegacyMigrationOutcome] = [:]

    public var imported: [String] { keys { $0 == .imported } }
    public var conflicts: [String] { keys { if case .conflict = $0 { return true } else { return false } } }

    public var isEmpty: Bool { outcomes.isEmpty }
    /// True when at least one host disagreed and nothing was decided.
    public var hasConflicts: Bool { !conflicts.isEmpty }

    private func keys(matching predicate: (LegacyMigrationOutcome) -> Bool) -> [String] {
        outcomes.filter { predicate($0.value) }.keys.sorted()
    }
}

/// Carries legacy trust into the canonical store, fail-closed.
public struct LegacyHostKeyMigrator: Sendable {
    private let store: CanonicalHostKeyStore
    private let source: any LegacyHostKeySource

    public init(store: CanonicalHostKeyStore, source: any LegacyHostKeySource) {
        self.store = store
        self.source = source
    }

    /// Run one migration pass.
    ///
    /// Idempotent: a host already carried over reports `alreadyPresent` and
    /// nothing is rewritten, so calling this on every launch is safe.
    @discardableResult
    public func migrate() throws -> LegacyMigrationReport {
        let legacy = source.legacyFingerprints()
        var report = LegacyMigrationReport()

        for (composite, fingerprint) in legacy {
            let parts = composite.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let port = UInt16(parts[1]), !parts[0].isEmpty else {
                report.outcomes[composite] = .malformedKey(composite)
                continue
            }
            let host = String(parts[0])

            // Decide per host before writing anything, so a conflict is detected
            // without a partial write having already happened.
            let lookup = try store.lookup(host: host, port: port)
            switch lookup {
            case .absent, .invalidOrCorrupt:
                // Nothing trustworthy to compare against; the pin is carried over
                // and the resolver will verify it against the live key before it
                // is allowed to authorise anything.
                report.outcomes[composite] = .imported

            case let .legacyFingerprintOnly(existing):
                if existing == fingerprint {
                    report.outcomes[composite] = .alreadyPresent
                } else {
                    // The store already carries a pin for this host and it differs
                // from the legacy one. Leave both alone.
                    report.outcomes[composite] = .conflict(canonical: existing, legacy: fingerprint)
                }

            case let .complete(record):
                if record.fingerprint == fingerprint {
                    report.outcomes[composite] = .alreadyPresent
                } else {
                    report.outcomes[composite] = .conflict(
                        canonical: record.fingerprint, legacy: fingerprint
                    )
                }
            }
        }

        // Only the hosts that carried over are written. Conflicting hosts are
        // deliberately absent from this call, which is what makes the conflict
        // inert rather than merely reported.
        let importable = legacy.filter { composite, _ in
            report.outcomes[composite] == .imported
        }
        if !importable.isEmpty {
            try store.importLegacyFingerprints(importable)
        }
        return report
    }
}