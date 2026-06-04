//
//  UpdaterManager.swift
//  Bonk
//
//  Wraps Sparkle's SPUStandardUpdaterController for SwiftUI.
//

import Combine
import Foundation

#if canImport(Sparkle)
import Sparkle

final class UpdaterManager: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = true

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
// Stub when Sparkle is not yet added as a dependency
final class UpdaterManager: ObservableObject {
    @Published var canCheckForUpdates = true
    func checkForUpdates() {}
}
#endif
