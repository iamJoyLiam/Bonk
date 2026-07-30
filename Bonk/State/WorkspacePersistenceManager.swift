//
//  WorkspacePersistenceManager.swift
//  Bonk
//
//  Manages workspace save/load operations.
//

import Foundation
import os
import SwiftData

/// Manages workspace persistence and restoration.
@MainActor
final class WorkspacePersistenceManager {
    static let shared = WorkspacePersistenceManager()

    private init() {}

    // MARK: - Save

    /// Save current session state as a new workspace.
    func saveWorkspace(
        name: String,
        sessionManager: SessionManager,
        modelContext: ModelContext
    ) -> Workspace {
        let workspace = Workspace.from(sessionManager: sessionManager, name: name)
        modelContext.insert(workspace)

        do {
            try modelContext.save()
            Log.session.info("Workspace '\(name)' saved with \(workspace.tabs.count) tabs")
        } catch {
            Log.session.error("Failed to save workspace: \(error.localizedDescription)")
        }

        return workspace
    }

    // MARK: - Load

    /// Restore a workspace by opening all its tabs.
    func loadWorkspace(
        _ workspace: Workspace,
        sessionManager: SessionManager,
        hostStore: [UUID: HostItem] = [:]
    ) {
        // Close all existing tabs first
        for tab in sessionManager.tabs {
            Task {
                await sessionManager.closeTab(tab.id)
            }
        }

        // Open tabs from workspace
        for workspaceTab in workspace.tabs.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            // Find the host item
            guard let hostItem = hostStore[workspaceTab.hostItemID] else {
                Log.session.warning("Host item not found for workspace tab: \(workspaceTab.hostItemID)")
                continue
            }

            // Create and open the tab
            let tab = TerminalTab(hostItem: hostItem)
            tab.title = workspaceTab.title
            tab.colorLabel = workspaceTab.colorLabel
            tab.isBroadcastEnabled = workspaceTab.isBroadcastEnabled

            // Add to session manager
            sessionManager.tabs.append(tab)

            // Connect asynchronously
            Task {
                await sessionManager.connectTab(tab)
            }
        }

        // Restore active tab
        if workspace.activeTabIndex < sessionManager.tabs.count {
            sessionManager.activeTabID = sessionManager.tabs[workspace.activeTabIndex].id
        }

        Log.session.info("Workspace '\(workspace.name)' loaded with \(workspace.tabs.count) tabs")
    }

    // MARK: - Delete

    /// Delete a workspace.
    func deleteWorkspace(_ workspace: Workspace, modelContext: ModelContext) {
        modelContext.delete(workspace)
        do {
            try modelContext.save()
            Log.session.info("Workspace '\(workspace.name)' deleted")
        } catch {
            Log.session.error("Failed to delete workspace: \(error.localizedDescription)")
        }
    }

    // MARK: - Rename

    /// Rename a workspace.
    func renameWorkspace(_ workspace: Workspace, to newName: String, modelContext: ModelContext) {
        workspace.name = newName
        workspace.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            Log.session.error("Failed to rename workspace: \(error.localizedDescription)")
        }
    }
}
