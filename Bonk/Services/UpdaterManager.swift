//
//  UpdaterManager.swift
//  Bonk
//
//  Wraps Sparkle's SPUStandardUpdaterController for SwiftUI.
//

import Foundation

#if canImport(Sparkle)
    import Sparkle

    @Observable
    final class UpdaterManager {
        private let updaterController: SPUStandardUpdaterController

        var canCheckForUpdates = true

        init() {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
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
        var canCheckForUpdates = true
        func checkForUpdates() {}
    }
#endif
