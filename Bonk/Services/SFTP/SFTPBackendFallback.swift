//
//  SFTPBackendFallback.swift
//  Bonk
//
//  Whether a failed SFTP connection may be retried on the other backend.
//
//  Bonk has two SFTP transports and two *independent* host-key trust stores:
//
//    Citadel  -> PersistentHostKeyStore, UserDefaults key "com.bonk.hostKeys"
//    OpenSSH  -> <App Support>/known_hosts, StrictHostKeyChecking=accept-new
//
//  That second line is the whole problem. A host-key mismatch raised by the
//  Citadel leg means a key we already trust was replaced. Retrying on OpenSSH
//  does not retry the *check*: OpenSSH consults a store that has never seen this
//  host, so `accept-new` accepts the key that Citadel just rejected and writes
//  it to disk as trusted. A detected MITM becomes a silent one.
//
//  So the two errors are not interchangeable, and an untyped `catch` that treats
//  them the same is a trust downgrade, not a resilience measure. Falling back is
//  for failures where the *transport* failed — the host key was never in doubt.
//
//  The sequence lives here rather than inline so it can be exercised without a
//  live SSH server: the legs are closures, so a test can observe exactly how
//  many times each one ran.
//

import Foundation
import os.log

/// The two transports a Citadel-first SFTP connection can attempt, as closures.
///
/// `@MainActor` because `SFTPService` is, and both legs mutate its channel
/// state. Isolating the legs here means `run` is the *same* function production
/// executes — an earlier version kept the gate in `SFTPService` and mirrored it
/// here for the tests, which meant the tests exercised a copy and the real gate
/// could be deleted with the suite still green.
struct SFTPBackendLegs {
    /// The Citadel/native attempt. Throws whatever the SSH layer threw.
    let citadel: @MainActor () async throws -> Void
    /// The OpenSSH attempt. `nil` where OpenSSH is unavailable, which is
    /// equivalent to declining the fallback.
    let openSSH: (@MainActor () async throws -> Void)?

    init(
        citadel: @escaping @MainActor () async throws -> Void,
        openSSH: (@MainActor () async throws -> Void)? = nil
    ) {
        self.citadel = citadel
        self.openSSH = openSSH
    }
}

enum SFTPBackendFallback {
    private static let logger = Logger(subsystem: "com.bonk", category: "SFTP")

    /// Is this failure one where the other backend is worth trying?
    ///
    /// `false` for a host-key trust failure, and that is the only category
    /// excluded. Everything else — a refused connection, a timeout, a channel
    /// that would not open — is a transport failure where the host key was never
    /// in question, so trying the other transport says nothing new about trust
    /// and rescues a user who would otherwise lose file access.
    static func permitsFallback(_ error: Error) -> Bool {
        !isHostKeyTrustFailure(error)
    }

    /// Does this error report a host key that did not match what we trust?
    ///
    /// Delegates to the one definition the session path already uses, so the two
    /// cannot drift. See `SSHFailureClassification.isHostKeyTrustFailure`.
    static func isHostKeyTrustFailure(_ error: Error) -> Bool {
        SSHFailureClassification.isHostKeyTrustFailure(error)
    }

    /// Connect, falling back only for failures that permit it.
    ///
    /// On a host-key failure this rethrows without touching the second transport,
    /// so nothing can consult the other store or accept the key that was just
    /// rejected. If the fallback itself fails, the *original* error is thrown:
    /// it is the one that explains what actually went wrong.
    @MainActor
    static func run(_ legs: SFTPBackendLegs) async throws {
        do {
            try await legs.citadel()
            return
        } catch {
            // Bound to a name, because the inner `catch` below would otherwise
            // shadow `error` and report the fallback's failure as the cause.
            let primary = error
            guard let openSSH = legs.openSSH, permitsFallback(primary) else {
                if isHostKeyTrustFailure(primary) {
                    logger.error("[SFTP] host key trust failure; not falling back to another transport")
                }
                throw primary
            }
            logger.warning("[SFTP] transport failed, falling back to OpenSSH")
            do {
                try await openSSH()
            } catch {
                throw primary
            }
        }
    }
}
