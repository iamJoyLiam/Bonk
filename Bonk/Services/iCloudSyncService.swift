//
//  iCloudSyncService.swift
//  Bonk
//
//  iCloud sync using NSUbiquitousKeyValueStore.
//  No paid Apple Developer account required.
//

import Foundation
import SwiftUI

/// Service for syncing preferences and host data via iCloud.
@Observable @MainActor
final class iCloudSyncService {
    /// Shared instance.
    static let shared = iCloudSyncService()

    /// The ubiquitous key-value store.
    private let store = NSUbiquitousKeyValueStore.default

    /// Whether sync is enabled.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "sync_icloud")
            if isEnabled {
                startSyncing()
            } else {
                stopSyncing()
            }
        }
    }

    /// Last sync timestamp.
    var lastSynced: Date?

    /// Sync error message.
    var syncError: String?

    /// Keys used for storage.
    private enum Keys {
        static let hosts = "bonk_hosts"
        static let preferences = "bonk_preferences"
        static let lastSynced = "bonk_last_synced"
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "sync_icloud")

        if isEnabled {
            startSyncing()
        }
    }

    /// Start observing iCloud changes.
    private func startSyncing() {
        // Listen for external changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )

        // Trigger initial sync
        store.synchronize()

        // Sync local data to iCloud
        syncToCloud()
    }

    /// Stop observing iCloud changes.
    private func stopSyncing() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
    }

    /// Handle external iCloud changes.
    @objc private func storeDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        else {
            return
        }

        // Only process server changes and initial sync
        guard reason == NSUbiquitousKeyValueStoreServerChange ||
            reason == NSUbiquitousKeyValueStoreInitialSyncChange
        else {
            return
        }

        syncFromCloud()
    }

    /// Sync local data to iCloud.
    func syncToCloud() {
        guard isEnabled else { return }

        // Sync preferences if enabled
        if UserDefaults.standard.bool(forKey: "sync_prefs") {
            syncPreferencesToCloud()
        }

        // Sync hosts if enabled
        if UserDefaults.standard.bool(forKey: "sync_hosts") {
            syncHostsToCloud()
        }

        // Update last synced timestamp
        lastSynced = Date()
        store.set(lastSynced?.timeIntervalSince1970 ?? 0, forKey: Keys.lastSynced)
    }

    /// Sync data from iCloud to local.
    func syncFromCloud() {
        guard isEnabled else { return }

        // Sync preferences if enabled
        if UserDefaults.standard.bool(forKey: "sync_prefs") {
            syncPreferencesFromCloud()
        }

        // Sync hosts if enabled
        if UserDefaults.standard.bool(forKey: "sync_hosts") {
            syncHostsFromCloud()
        }

        // Update last synced timestamp
        let cloudTimestamp = store.double(forKey: Keys.lastSynced)
        if cloudTimestamp > 0 {
            lastSynced = Date(timeIntervalSince1970: cloudTimestamp)
        }
    }

    // MARK: - Preferences Sync

    private func syncPreferencesToCloud() {
        let prefs: [String: Any] = [
            "fontSize": UserDefaults.standard.double(forKey: "fontSize"),
            "defaultPort": UserDefaults.standard.integer(forKey: "defaultPort"),
            "scrollbackLines": UserDefaults.standard.integer(forKey: "scrollbackLines"),
            "optionAsMeta": UserDefaults.standard.bool(forKey: "optionAsMeta"),
            "mouseReporting": UserDefaults.standard.bool(forKey: "mouseReporting"),
            "cursorStyle": UserDefaults.standard.string(forKey: "terminalCursorStyle") ?? "block",
            "cursorBlink": UserDefaults.standard.bool(forKey: "terminalCursorBlink"),
            "copyOnSelect": UserDefaults.standard.bool(forKey: "copyOnSelect"),
            "restoreSessions": UserDefaults.standard.bool(forKey: "restoreSessions"),
            "checkForUpdates": UserDefaults.standard.bool(forKey: "checkForUpdates"),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: prefs),
           let json = String(data: data, encoding: .utf8)
        {
            store.set(json, forKey: Keys.preferences)
        }
    }

    private func syncPreferencesFromCloud() {
        guard let json = store.string(forKey: Keys.preferences),
              let data = json.data(using: .utf8),
              let prefs = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        // Apply preferences from cloud (last writer wins)
        if let fontSize = prefs["fontSize"] as? Double {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
        }
        if let defaultPort = prefs["defaultPort"] as? Int {
            UserDefaults.standard.set(defaultPort, forKey: "defaultPort")
        }
        if let scrollbackLines = prefs["scrollbackLines"] as? Int {
            UserDefaults.standard.set(scrollbackLines, forKey: "scrollbackLines")
        }
        if let optionAsMeta = prefs["optionAsMeta"] as? Bool {
            UserDefaults.standard.set(optionAsMeta, forKey: "optionAsMeta")
        }
        if let mouseReporting = prefs["mouseReporting"] as? Bool {
            UserDefaults.standard.set(mouseReporting, forKey: "mouseReporting")
        }
        if let cursorStyle = prefs["cursorStyle"] as? String {
            UserDefaults.standard.set(cursorStyle, forKey: "terminalCursorStyle")
        }
        if let cursorBlink = prefs["cursorBlink"] as? Bool {
            UserDefaults.standard.set(cursorBlink, forKey: "terminalCursorBlink")
        }
        if let copyOnSelect = prefs["copyOnSelect"] as? Bool {
            UserDefaults.standard.set(copyOnSelect, forKey: "copyOnSelect")
        }
        if let restoreSessions = prefs["restoreSessions"] as? Bool {
            UserDefaults.standard.set(restoreSessions, forKey: "restoreSessions")
        }
        if let checkForUpdates = prefs["checkForUpdates"] as? Bool {
            UserDefaults.standard.set(checkForUpdates, forKey: "checkForUpdates")
        }
    }

    // MARK: - Hosts Sync

    private func syncHostsToCloud() {
        // Hosts are stored in SwiftData, we sync a simplified version
        // Credentials are NOT synced (they stay in Keychain)
        // This is a placeholder - actual implementation would need SwiftData context
    }

    private func syncHostsFromCloud() {
        // Hosts sync from cloud - placeholder
    }
}
