//
//  SessionRestore.swift
//  Bonk
//
//  Reopen the pre-update terminal tabs after a Sparkle relaunch.
//
//  Protocol:
//  - Sparkle's updaterWillRelaunchApplication sets a one-shot flag.
//  - applicationWillTerminate snapshots open tabs (host UUIDs only —
//    credentials stay in the Keychain, tab order + active tab preserved).
//  - On next launch, ContentView consumes the flag once and reopens each
//    host via the normal openHost path (serial dispatch + connect included).
//  - Normal quits also snapshot, but without the flag nothing is restored.
//
//  Known v1 limits: split panes with a foreign host collapse to the tab's
//  own host; transient serial tabs (host not in the DB) are skipped.

import Foundation
import SwiftData

enum SessionRestore {
    private static let flagKey = "bonk.restoreTabsAfterUpdate"
    private static let tabsKey = "bonk.openTabHostIDs"
    private static let activeKey = "bonk.activeTabHostID"

    /// Called by the Sparkle updater delegate right before relaunch.
    static func markRelaunchForUpdate() {
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// Snapshot open tabs. Called from applicationWillTerminate (Sparkle
    /// relaunch always goes through the normal terminate sequence).
    @MainActor
    static func snapshot(tabs: [TerminalTab], activeTabID: UUID?) {
        UserDefaults.standard.set(tabs.map(\.hostItem.id.uuidString), forKey: tabsKey)
        if let active = tabs.first(where: { $0.id == activeTabID }) {
            UserDefaults.standard.set(active.hostItem.id.uuidString, forKey: activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeKey)
        }
    }

    /// Reopen snapshotted tabs if the previous run relaunched for an update.
    /// One-shot: the flag is cleared before doing anything, so repeat
    /// onAppear calls can never double-restore. Returns true when tabs
    /// were reopened.
    @MainActor
    @discardableResult
    static func restoreIfNeeded(sessionManager: SessionManager, context: ModelContext) -> Bool {
        guard UserDefaults.standard.bool(forKey: flagKey) else { return false }
        UserDefaults.standard.set(false, forKey: flagKey)

        let ids = UserDefaults.standard.stringArray(forKey: tabsKey) ?? []
        guard !ids.isEmpty else { return false }

        var hosts: [HostItem] = []
        hosts.reserveCapacity(ids.count)
        for raw in ids {
            guard let uuid = UUID(uuidString: raw) else { continue }
            var descriptor = FetchDescriptor<HostItem>(predicate: #Predicate { $0.id == uuid })
            descriptor.fetchLimit = 1
            if let host = try? context.fetch(descriptor).first {
                hosts.append(host)
            }
        }
        for host in hosts {
            sessionManager.openHost(host)
        }
        if let activeRaw = UserDefaults.standard.string(forKey: activeKey),
           let activeUUID = UUID(uuidString: activeRaw),
           let tab = sessionManager.tabs.first(where: { $0.hostItem.id == activeUUID })
        {
            sessionManager.activeTabID = tab.id
        }
        return !hosts.isEmpty
    }
}
