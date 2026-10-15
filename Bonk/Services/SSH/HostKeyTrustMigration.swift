//
//  HostKeyTrustMigration.swift
//  Bonk
//
//  Runs the legacy host-key migration once per launch and makes its outcome
//  legible.
//
//  ## Why it is separate from `LegacyHostKeyMigrator`
//
//  The migrator is pure logic over an injected source and a temp-or-production
//  store, which is what makes it testable. This type is the part that is *not*:
//  it names the production store and the standard defaults domain, so it cannot
//  be exercised from a test without reaching the user's real data. Keeping it in
//  its own file means the testable half has no production-only imports, and a
//  reviewer can see exactly which code touches real user state.
//
//  ## Failure is contained
//
//  A migration that cannot run — a store that will not open, a defaults domain
//  that cannot be read — must not stop the app from launching. Trust then stays
//  where it was, which is the conservative outcome: first contact happens again
//  for an unpinned host, but nothing is granted that was not already granted.
//  The alternative, refusing to launch, turns a recoverable migration problem
//  into an outage.
//

import Foundation
import NIOConcurrencyHelpers
import os.log

/// Launch-time entry point for the legacy host-key migration.
public enum HostKeyTrustMigration {
    /// Whether the migration has already run in this process.
    ///
    /// `BonkApp.init` runs once per launch, but the launch path is not the only
    /// thing that touches trust, and a second pass must never be able to race the
    /// first. `migrate()` is idempotent regardless; this only avoids repeating
    /// the work.
    private static let hasRun = NIOLockedValueBox(false)

    /// Run the migration if it has not already run in this process.
    ///
    /// Never throws: a migration failure is logged and the app continues with the
    /// legacy table untouched.
    public static func runAtLaunch() {
        let alreadyRan = hasRun.withLockedValue { done -> Bool in
            defer { done = true }
            return done
        }
        guard !alreadyRan else { return }

        do {
            let store = try CanonicalHostKeyStore(
                fileURL: try CanonicalHostKeyStore.defaultFileURL()
            )
            let report = try LegacyHostKeyMigrator(
                store: store,
                source: UserDefaultsLegacyHostKeySource(defaults: .standard)
            ).migrate()

            if report.hasConflicts {
                // Not an error: the migration refuses to decide, and says so. The
                // affected hosts will surface at connection time as a refusal to
                // trust, which is the correct fail-closed behaviour and is far
                // better than a migration that quietly picks a winner.
                Log.ssh.warning(
                    "[HOSTKEY_MIGRATION] conflicts=\(report.conflicts.count, privacy: .public) unresolved; no trust state was modified"
                )
            }
            if !report.imported.isEmpty {
                Log.ssh.info(
                    "[HOSTKEY_MIGRATION] imported=\(report.imported.count, privacy: .public) conflicts=\(report.conflicts.count, privacy: .public)"
                )
            }
        } catch {
            // Contained deliberately: see the type comment. Trust is unchanged,
            // which is the safe direction.
            Log.ssh.error(
                "[HOSTKEY_MIGRATION] failed; legacy trust left in place: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}