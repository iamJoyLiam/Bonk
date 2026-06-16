import os.log
import SwiftData
import SwiftUI

/// Service for syncing preferences via iCloud key-value store.
/// Reads from SwiftData (single source of truth), syncs to iCloud KV store.
@Observable @MainActor
final class ICloudSyncService {
    static let shared = ICloudSyncService()
    private static let logger = Logger(subsystem: "com.bonk", category: "iCloudSync")

    private let store = NSUbiquitousKeyValueStore.default
    private var modelContext: ModelContext?

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

    var lastSynced: Date?
    var syncError: String?

    private enum Keys {
        static let preferences = "bonk_preferences"
        static let lastSynced = "bonk_last_synced"
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "sync_icloud")
        if isEnabled {
            startSyncing()
        }
    }

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    // MARK: - Sync Lifecycle

    private func startSyncing() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        store.synchronize()
        syncToCloud()
    }

    private func stopSyncing() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
    }

    @objc private func storeDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else
        {
            return
        }
        guard reason == NSUbiquitousKeyValueStoreServerChange ||
            reason == NSUbiquitousKeyValueStoreInitialSyncChange else
        {
            return
        }
        syncFromCloud()
    }

    // MARK: - Sync To Cloud

    func syncToCloud() {
        guard isEnabled, let context = modelContext else { return }

        do {
            let desc = FetchDescriptor<UserPreferences>()
            guard let prefs = try context.fetch(desc).first else { return }

            let snapshot = SyncSnapshot(from: prefs)
            let data = try JSONEncoder().encode(snapshot)
            guard let json = String(data: data, encoding: .utf8) else {
                syncError = "Encoding failed"
                return
            }
            store.set(json, forKey: Keys.preferences)
            syncError = nil
            lastSynced = Date()
            store.set(lastSynced?.timeIntervalSince1970 ?? 0, forKey: Keys.lastSynced)
        } catch {
            syncError = error.localizedDescription
            Self.logger.error("syncToCloud failed: \(error)")
        }
    }

    // MARK: - Sync From Cloud

    func syncFromCloud() {
        guard isEnabled, let context = modelContext else { return }

        guard let json = store.string(forKey: Keys.preferences),
              let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(SyncSnapshot.self, from: data) else
        {
            return
        }

        let desc = FetchDescriptor<UserPreferences>()
        guard let prefs = try? context.fetch(desc).first else { return }

        snapshot.apply(to: prefs)

        do {
            try context.save()
        } catch {
            Self.logger.error("syncFromCloud save failed: \(error)")
        }

        let cloudTimestamp = store.double(forKey: Keys.lastSynced)
        if cloudTimestamp > 0 {
            lastSynced = Date(timeIntervalSince1970: cloudTimestamp)
        }
    }
}

// MARK: - Codable Sync Snapshot

/// All syncable preference fields in one struct.
/// Adding a new field here automatically includes it in sync.
private struct SyncSnapshot: Codable {
    var fontSize: Double
    var fontFamily: String
    var lineHeight: Double
    var defaultPort: Int
    var scrollbackLines: Int
    var optionAsMeta: Bool
    var mouseReporting: Bool
    var cursorStyle: String
    var cursorBlink: Bool
    var copyOnSelect: Bool
    var escDismissAI: Bool
    var hostAutoFillClear: Bool
    var aiDirectSubmit: Bool
    var restoreSessions: Bool
    var checkForUpdates: Bool

    init(from prefs: UserPreferences) {
        fontSize = prefs.fontSize
        fontFamily = prefs.fontFamily
        lineHeight = prefs.lineHeight
        defaultPort = prefs.defaultPort
        scrollbackLines = prefs.scrollbackLines
        optionAsMeta = prefs.optionAsMeta
        mouseReporting = prefs.mouseReporting
        cursorStyle = prefs.cursorStyle
        cursorBlink = prefs.cursorBlink
        copyOnSelect = prefs.copyOnSelect
        escDismissAI = prefs.escDismissAI
        hostAutoFillClear = prefs.hostAutoFillClear
        aiDirectSubmit = prefs.aiDirectSubmit
        restoreSessions = prefs.restoreSessions
        checkForUpdates = prefs.checkForUpdates
    }

    func apply(to prefs: UserPreferences) {
        prefs.fontSize = fontSize
        prefs.fontFamily = fontFamily
        prefs.lineHeight = lineHeight
        prefs.defaultPort = defaultPort
        prefs.scrollbackLines = scrollbackLines
        prefs.optionAsMeta = optionAsMeta
        prefs.mouseReporting = mouseReporting
        prefs.cursorStyle = cursorStyle
        prefs.cursorBlink = cursorBlink
        prefs.copyOnSelect = copyOnSelect
        prefs.escDismissAI = escDismissAI
        prefs.hostAutoFillClear = hostAutoFillClear
        prefs.aiDirectSubmit = aiDirectSubmit
        prefs.restoreSessions = restoreSessions
        prefs.checkForUpdates = checkForUpdates
    }
}
