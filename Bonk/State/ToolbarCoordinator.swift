//
//  ToolbarCoordinator.swift
//  Bonk
//
//  Shared state for toolbar and sheet presentations.
//

import SwiftUI
import SwiftData

@Observable
@MainActor
final class ToolbarCoordinator {
    var workspace: WorkspaceManager
    var sessionManager: SessionManager
    var i18n: I18n
    var modelContext: ModelContext?

    // Sheet presentations
    var showKeyGenerator = false
    var showWorkspaces = false
    var showSSHConfigImport = false
    var showTabbyImport = false
    var showUnifiedImport = false
    var showAddHostSheet = false
    var showRecordings = false
    var showJumpHosts = false
    var showTriggers = false
    var showTeam = false

    init(workspace: WorkspaceManager, sessionManager: SessionManager, i18n: I18n) {
        self.workspace = workspace
        self.sessionManager = sessionManager
        self.i18n = i18n
    }

    func showSnippets() {
        workspace.snippetsHistoryTab = .snippets
        workspace.toggleRightPanel(.snippetsHistory)
    }
}
