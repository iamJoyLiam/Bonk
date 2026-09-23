//
//  UpdaterManager.swift
//  Bonk
//
//  Wraps Sparkle's SPUStandardUpdaterController for SwiftUI.
//

import Foundation
import SwiftData

#if canImport(Sparkle)
    import Sparkle

    /// Marks a pending tab restore when Sparkle is about to relaunch the
    /// app for an update. Retained by UpdaterManager (delegate is weak).
    private final class BonkUpdaterDelegate: NSObject, SPUUpdaterDelegate {
        func updaterWillRelaunchApplication(_: SPUUpdater) {
            SessionRestore.markRelaunchForUpdate()
        }
    }

    @Observable
    @MainActor
    final class UpdaterManager {
        /// Shared instance: BonkApp and Settings both drive the same controller.
        static let shared = UpdaterManager()

        /// UserDefaults key Sparkle itself honors for scheduled checks.
        private static let automaticChecksKey = "SUEnableAutomaticChecks"

        private let updaterController: SPUStandardUpdaterController
        private let updaterDelegate = BonkUpdaterDelegate()

        init() {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: updaterDelegate,
                userDriverDelegate: nil
            )
            // Apply the stored preference at launch; Settings flips it live.
            // (Sparkle's own default is YES, so an explicit stored NO must win
            // before the first scheduled check.)
            setAutomaticChecks(Self.storedPreference())
        }

        func checkForUpdates() {
            updaterController.checkForUpdates(nil)
        }

        /// Wire the Settings toggle to Sparkle: live updater plus the
        /// UserDefaults key Sparkle reads, so both current and future
        /// sessions honor it.
        func setAutomaticChecks(_ enabled: Bool) {
            updaterController.updater.automaticallyChecksForUpdates = enabled
            UserDefaults.standard.set(enabled, forKey: Self.automaticChecksKey)
        }

        private static func storedPreference() -> Bool {
            // Best effort: no row yet on first launch → default YES.
            // CRITICAL: never open a second container here. A partial-schema,
            // file-backed container against the live store makes SwiftData
            // migration DROP every table outside its model (2026.4.3 wiped
            // all hosts this way). Always read through the shared container.
            let context = ModelContext(BonkApp.sharedModelContainer)
            let prefs = (try? context.fetch(FetchDescriptor<UserPreferences>())) ?? []
            return prefs.first?.checkForUpdates ?? true
        }
    }
#else
    /// Stub when Sparkle is not yet added as a dependency
    @Observable
    final class UpdaterManager {
        func checkForUpdates() {}
    }
#endif
