//
//  LogColorizerConfig.swift
//  Bonk
//
//  User-facing configuration for log colorization.
//  Uses UserDefaults directly for thread-safe access from nonisolated PTYSession.
//

import Foundation

enum LogColorizerConfig {

    // MARK: - Storage Keys

    private static let enabledKey = "logColorizerEnabled"

    // MARK: - Public State

    /// Global toggle for log colorization. Default: true.
    /// Thread-safe via UserDefaults (atomic reads).
    nonisolated(unsafe) static var isEnabled: Bool {
        get {
            // If key has never been set, default to true (enabled)
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}
