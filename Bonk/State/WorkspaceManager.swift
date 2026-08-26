//
//  WorkspaceManager.swift
//  Bonk
//
//  Central @Observable state manager.
//

import SwiftUI

@Observable
@MainActor
final class WorkspaceManager {
    init() {
        // Clean up legacy Focus Mode flag that previously created the sidebar "box".
        // The feature was permanently removed in v2026.2.3; leftover defaults should not linger.
        if UserDefaults.standard.object(forKey: "workspace_focus_mode") != nil {
            UserDefaults.standard.removeObject(forKey: "workspace_focus_mode")
        }
    }

    // MARK: - Right Sidebar Inspectors

    /// Which right sidebar inspector is active (only one at a time).
    enum RightPanel: String, Identifiable {
        case none
        case ai
        case snippetsHistory
        case serverInfo

        var id: String {
            rawValue
        }
    }

    var activeRightPanel: RightPanel = .none

    /// Whether the inspector split item is currently collapsed. Manual
    /// divider drags collapse/expand it without touching `activeRightPanel`,
    /// so the toggle needs this to reopen the same panel.
    var isInspectorCollapsed = true

    // MARK: - Snippets/History Sub-tab

    enum SnippetsHistoryTab: String, CaseIterable, Identifiable {
        case snippets = "Snippets"
        case history = "History"

        var id: String {
            rawValue
        }
    }

    var snippetsHistoryTab: SnippetsHistoryTab = .snippets

    // MARK: - SFTP Window

    var isSFTPWindowOpen = false

    // MARK: - Team Live Window (independent, like SFTP)

    var isTeamWindowOpen = false

    // MARK: - Title Bar Sheet Presentations

    let broadcastManager = BroadcastManager()

    var isSerialPortPresented = false
    var isPortForwardingPresented = false

    // MARK: - Right Panel Actions

    func toggleRightPanel(_ panel: RightPanel) {
        if activeRightPanel == panel {
            if isInspectorCollapsed {
                // Reopen the collapsed inspector with the same panel. Write
                // through `.none` so the change is observed.
                activeRightPanel = .none
                activeRightPanel = panel
            } else {
                activeRightPanel = .none
            }
        } else {
            activeRightPanel = panel
        }
    }

    func toggleSFTPWindow() {
        isSFTPWindowOpen.toggle()
    }

    func toggleTeamWindow() {
        isTeamWindowOpen.toggle()
    }

    func toggleBroadcast() {
        broadcastManager.toggle()
    }
}
