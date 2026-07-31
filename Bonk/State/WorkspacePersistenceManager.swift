//
//  WorkspacePersistenceManager.swift
//  Bonk
//
//  Manages workspace save/load operations using plist files.
//  Workspace is UI state, not business data - belongs in plist, not SwiftData.
//

import Foundation
import os
import SwiftData

/// Manages workspace persistence using plist files.
/// Workspace is application state (tabs, layout, UI), not business data.
/// This follows macOS convention (like iTerm2 arrangements, Xcode schemes).
@MainActor
final class WorkspacePersistenceManager {
    static let shared = WorkspacePersistenceManager()

    private let logger = Logger(subsystem: "com.bonk", category: "Workspace")
    private let workspacesDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        workspacesDirectory = appSupport.appendingPathComponent("Workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspacesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Data Models

    struct WorkspaceData: Codable, Identifiable {
        let id: UUID
        var name: String
        let createdAt: Date
        var updatedAt: Date
        var activeTabIndex: Int
        var tabs: [WorkspaceTabData]
    }

    struct WorkspaceTabData: Codable, Identifiable {
        let id: UUID // Use tab.id for stable identity
        let hostItemID: UUID
        var title: String
        var colorLabel: String?
        var sortOrder: Int
        var isBroadcastEnabled: Bool
        var activePaneID: UUID?
    }

    // MARK: - Save

    /// Save or update a workspace.
    /// If workspaceID is nil, creates a new workspace.
    /// If workspaceID is provided, updates the existing workspace.
    func saveWorkspace(
        name: String,
        sessionManager: SessionManager,
        existingWorkspaceID: UUID? = nil
    ) -> WorkspaceData? {
        var workspaceTabs: [WorkspaceTabData] = []

        for (index, tab) in sessionManager.tabs.enumerated() {
            let workspaceTab = WorkspaceTabData(
                id: tab.id, // Use tab.id for stable identity
                hostItemID: tab.hostItem.id,
                title: tab.title,
                colorLabel: tab.colorLabel,
                sortOrder: index,
                isBroadcastEnabled: tab.isBroadcastEnabled,
                activePaneID: tab.activePaneID
            )
            workspaceTabs.append(workspaceTab)
        }

        let activeIndex = sessionManager.tabs.firstIndex { $0.id == sessionManager.activeTabID } ?? 0

        let workspace: WorkspaceData
        if let existingID = existingWorkspaceID, var existing = loadWorkspace(id: existingID) {
            // Update existing workspace
            existing.name = name
            existing.updatedAt = Date()
            existing.activeTabIndex = activeIndex
            existing.tabs = workspaceTabs
            workspace = existing
        } else {
            // Create new workspace
            workspace = WorkspaceData(
                id: UUID(),
                name: name,
                createdAt: Date(),
                updatedAt: Date(),
                activeTabIndex: activeIndex,
                tabs: workspaceTabs
            )
        }

        let fileURL = workspacesDirectory.appendingPathComponent("\(workspace.id.uuidString).plist")
        do {
            let data = try PropertyListEncoder().encode(workspace)
            try data.write(to: fileURL)
            logger.info("Workspace '\(name)' saved successfully")
            return workspace
        } catch {
            logger.error("Failed to save workspace: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Load

    /// Load all workspaces from plist files.
    func loadAllWorkspaces() -> [WorkspaceData] {
        var workspaces: [WorkspaceData] = []

        guard let files = try? FileManager.default.contentsOfDirectory(at: workspacesDirectory, includingPropertiesForKeys: nil) else {
            return workspaces
        }

        for file in files where file.pathExtension == "plist" {
            if let data = try? Data(contentsOf: file),
               let workspace = try? PropertyListDecoder().decode(WorkspaceData.self, from: data)
            {
                workspaces.append(workspace)
            }
        }

        return workspaces.sorted { $0.createdAt > $1.createdAt }
    }

    /// Load a single workspace.
    func loadWorkspace(id: UUID) -> WorkspaceData? {
        let fileURL = workspacesDirectory.appendingPathComponent("\(id.uuidString).plist")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode(WorkspaceData.self, from: data)
    }

    // MARK: - Delete

    /// Delete a workspace.
    func deleteWorkspace(id: UUID) {
        let fileURL = workspacesDirectory.appendingPathComponent("\(id.uuidString).plist")
        try? FileManager.default.removeItem(at: fileURL)
        logger.info("Workspace deleted")
    }

    // MARK: - Rename

    /// Rename a workspace.
    func renameWorkspace(id: UUID, to newName: String) {
        guard var workspace = loadWorkspace(id: id) else { return }
        workspace.name = newName
        workspace.updatedAt = Date()

        let fileURL = workspacesDirectory.appendingPathComponent("\(id.uuidString).plist")
        do {
            let data = try PropertyListEncoder().encode(workspace)
            try data.write(to: fileURL)
        } catch {
            logger.error("Failed to rename workspace: \(error.localizedDescription)")
        }
    }

    // MARK: - Restore

    /// Restore a workspace by opening its tabs.
    func restoreWorkspace(
        _ workspace: WorkspaceData,
        sessionManager: SessionManager,
        modelContext: ModelContext
    ) {
        // Close all existing tabs
        for tab in sessionManager.tabs {
            Task {
                await sessionManager.closeTab(tab.id)
            }
        }

        // Fetch host items for workspace tabs
        var hostStore: [UUID: HostItem] = [:]
        let descriptor = FetchDescriptor<HostItem>()
        if let hosts = try? modelContext.fetch(descriptor) {
            for host in hosts {
                hostStore[host.id] = host
            }
        }

        // Open tabs from workspace
        for workspaceTab in workspace.tabs.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let hostItem = hostStore[workspaceTab.hostItemID] else {
                logger.warning("Host item not found for workspace tab: \(workspaceTab.hostItemID)")
                continue
            }

            let tab = TerminalTab(hostItem: hostItem)
            tab.title = workspaceTab.title
            tab.colorLabel = workspaceTab.colorLabel
            tab.isBroadcastEnabled = workspaceTab.isBroadcastEnabled

            sessionManager.tabs.append(tab)

            Task {
                await sessionManager.connectTab(tab)
            }
        }

        // Restore active tab
        if workspace.activeTabIndex < sessionManager.tabs.count {
            sessionManager.activeTabID = sessionManager.tabs[workspace.activeTabIndex].id
        }

        logger.info("Workspace '\(workspace.name)' restored with \(workspace.tabs.count) tabs")
    }
}
