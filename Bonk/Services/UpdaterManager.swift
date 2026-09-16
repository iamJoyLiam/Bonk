//
//  UpdaterManager.swift
//  Bonk
//
//  Wraps Sparkle's SPUStandardUpdaterController for SwiftUI.
//

import Foundation

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
        private let updaterController: SPUStandardUpdaterController
        private let updaterDelegate = BonkUpdaterDelegate()

        init() {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: updaterDelegate,
                userDriverDelegate: nil
            )
        }

        func checkForUpdates() {
            updaterController.checkForUpdates(nil)
        }
    }
#else
    /// Stub when Sparkle is not yet added as a dependency
    @Observable
    final class UpdaterManager {
        func checkForUpdates() {}
    }
#endif
