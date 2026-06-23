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
    // MARK: - Right Sidebar Inspectors

    /// Which right sidebar inspector is active (only one at a time).
    enum RightPanel: String, Identifiable {
        case none
        case ai
        case snippetsHistory

        var id: String {
            rawValue
        }
    }

    var activeRightPanel: RightPanel = .none

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

    // MARK: - Title Bar Sheet Presentations

    let broadcastManager = BroadcastManager()
    var isBroadcastEnabled: Bool {
        broadcastManager.isEnabled
    }

    var isSerialPortPresented = false
    var isPortForwardingPresented = false

    // MARK: - Right Panel Actions

    func toggleRightPanel(_ panel: RightPanel) {
        if activeRightPanel == panel {
            activeRightPanel = .none
        } else {
            activeRightPanel = panel
        }
    }

    func toggleSFTPWindow() {
        isSFTPWindowOpen.toggle()
    }

    func toggleBroadcast() {
        broadcastManager.toggle()
    }
}
