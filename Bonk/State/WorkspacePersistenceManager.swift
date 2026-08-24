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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
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
        var isTemplate: Bool? // nil = regular workspace, true = template
    }

    struct WorkspaceTabData: Codable, Identifiable {
        let id: UUID
        let hostItemID: UUID
        var title: String
        var colorLabel: String?
        var sortOrder: Int
        var isBroadcastEnabled: Bool
        var activePaneID: UUID?
        var paneIDs: [UUID]? // legacy, kept for migration
        var layout: LayoutNodeData? // new: full split tree with weights
    }

    indirect enum LayoutNodeData: Codable {
        case pane(PaneData)
        case horizontal(children: [LayoutNodeData], weights: [Double])
        case vertical(children: [LayoutNodeData], weights: [Double])

        struct PaneData: Codable {
            let id: UUID
            let hostItemID: UUID?
            let title: String
        }
    }

    // MARK: - Layout Conversion

    private func layoutData(from node: LayoutNode, tabHostID: UUID) -> LayoutNodeData {
        switch node {
        case let .pane(state):
            return LayoutNodeData.pane(LayoutNodeData.PaneData(id: state.id, hostItemID: state.hostItem?.id, title: state.title))
        case let .horizontal(children, weights):
            return LayoutNodeData.horizontal(children: children.map { layoutData(from: $0, tabHostID: tabHostID) }, weights: weights.map { Double($0) })
        case let .vertical(children, weights):
            return LayoutNodeData.vertical(children: children.map { layoutData(from: $0, tabHostID: tabHostID) }, weights: weights.map { Double($0) })
        }
    }

    private func layoutNode(from data: LayoutNodeData, hostStore: [UUID: HostItem], defaultHost: HostItem, idMap: inout [UUID: UUID]) -> LayoutNode {
        switch data {
        case let .pane(pane):
            let state = PaneState()
            idMap[pane.id] = state.id
            state.title = pane.title
            if let hid = pane.hostItemID, let host = hostStore[hid] {
                state.hostItem = host
            } else if pane.hostItemID == nil {
                // Inherit tab host (no override)
            } else if let hid = pane.hostItemID {
                state.hostItem = hostStore[hid] ?? defaultHost
            }
            return LayoutNode.pane(state)
        case let .horizontal(children, weights):
            let nodes = children.map { layoutNode(from: $0, hostStore: hostStore, defaultHost: defaultHost, idMap: &idMap) }
            return LayoutNode.horizontal(children: nodes, weights: weights.map { CGFloat($0) })
        case let .vertical(children, weights):
            let nodes = children.map { layoutNode(from: $0, hostStore: hostStore, defaultHost: defaultHost, idMap: &idMap) }
            return LayoutNode.vertical(children: nodes, weights: weights.map { CGFloat($0) })
        }
    }

    // MARK: - Save

    /// Save or update a workspace.
    /// If workspaceID is nil, creates a new workspace.
    /// If workspaceID is provided, updates the existing workspace.
    func saveWorkspace(
        name: String,
        sessionManager: SessionManager,
        existingWorkspaceID: UUID? = nil,
        isTemplate: Bool = false
    ) -> WorkspaceData? {
        var workspaceTabs: [WorkspaceTabData] = []

        for (index, tab) in sessionManager.tabs.enumerated() {
            let workspaceTab = WorkspaceTabData(
                id: tab.id,
                hostItemID: tab.hostItem.id,
                title: tab.title,
                colorLabel: tab.colorLabel,
                sortOrder: index,
                isBroadcastEnabled: tab.isBroadcastEnabled,
                activePaneID: tab.activePaneID,
                paneIDs: tab.paneIDs,
                layout: layoutData(from: tab.layout.root, tabHostID: tab.hostItem.id)
            )
            workspaceTabs.append(workspaceTab)
        }

        let activeIndex = sessionManager.tabs.firstIndex { $0.id == sessionManager.activeTabID } ?? 0

        let workspace: WorkspaceData
        if let existingID = existingWorkspaceID, var existing = loadWorkspace(id: existingID) {
            existing.name = name
            existing.updatedAt = Date()
            existing.activeTabIndex = activeIndex
            existing.tabs = workspaceTabs
            existing.isTemplate = isTemplate ? true : nil
            workspace = existing
        } else {
            workspace = WorkspaceData(
                id: UUID(),
                name: name,
                createdAt: Date(),
                updatedAt: Date(),
                activeTabIndex: activeIndex,
                tabs: workspaceTabs,
                isTemplate: isTemplate ? true : nil
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
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Workspace deleted")
        } catch {
            logger.warning("Failed to delete workspace: \(error.localizedDescription)")
        }
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
    ) async {
        for tab in sessionManager.tabs {
            await sessionManager.closeTab(tab.id)
        }

        // Collect all host IDs (tab + per-pane)
        var neededIDs = Set(workspace.tabs.map(\.hostItemID))
        for wt in workspace.tabs {
            if let layout = wt.layout {
                collectHosts(from: layout, into: &neededIDs)
            } else if let paneIDs = wt.paneIDs {
                // Legacy: paneIDs share tab host, no extra hosts
                _ = paneIDs
            }
        }
        var hostStore: [UUID: HostItem] = [:]
        let descriptor = FetchDescriptor<HostItem>()
        if let hosts = try? modelContext.fetch(descriptor) {
            for host in hosts where neededIDs.contains(host.id) {
                hostStore[host.id] = host
            }
        }

        for workspaceTab in workspace.tabs.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let hostItem = hostStore[workspaceTab.hostItemID] else {
                logger.warning("Host item not found for workspace tab: \(workspaceTab.hostItemID)")
                continue
            }
            let tab = TerminalTab(id: workspaceTab.id, hostItem: hostItem)
            tab.title = workspaceTab.title
            tab.colorLabel = workspaceTab.colorLabel
            tab.isBroadcastEnabled = workspaceTab.isBroadcastEnabled

            // Restore layout if available
            if let layoutData = workspaceTab.layout {
                var idMap: [UUID: UUID] = [:]
                let node = layoutNode(from: layoutData, hostStore: hostStore, defaultHost: hostItem, idMap: &idMap)
                tab.layout = TabLayout(root: node)
                if let oldActive = workspaceTab.activePaneID, let newActive = idMap[oldActive] {
                    tab.layout.activePaneID = newActive
                    tab.activePaneID = newActive
                } else {
                    tab.activePaneID = tab.layout.activePaneID
                }
            } else if let paneIDs = workspaceTab.paneIDs, paneIDs.count > 1 {
                // Legacy fallback: reconstruct simple horizontal splits
                // Keep first pane as is, add remaining as splits
                // This preserves old workspaces without layout data
                for _ in 1..<paneIDs.count {
                    _ = tab.layout.splitHorizontal()
                }
                if let active = workspaceTab.activePaneID { tab.activePaneID = active }
            }

            sessionManager.tabs.append(tab)
            // Connect primary pane via connectTab, additional panes via connectPane
            let allPanes = tab.layout.root.allPaneIDs
            Task {
                await sessionManager.connectTab(tab)
                // Small delay to let primary PTY establish, then connect splits
                try? await Task.sleep(for: .milliseconds(300))
                for pid in allPanes where pid != tab.layout.activePaneID {
                    if let pane = tab.layout.findPane(id: pid) {
                        await sessionManager.connectPane(tab: tab, pane: pane)
                    }
                }
                // Also ensure active pane is connected if it wasn't primary
                if let active = tab.activePaneID, !allPanes.isEmpty, allPanes.first != active {
                    if let pane = tab.layout.findPane(id: active) {
                        await sessionManager.connectPane(tab: tab, pane: pane)
                    }
                }
            }
        }

        if workspace.activeTabIndex < sessionManager.tabs.count {
            sessionManager.activeTabID = sessionManager.tabs[workspace.activeTabIndex].id
        }
        logger.info("Workspace '\(workspace.name)' restored with \(workspace.tabs.count) tabs (layout-aware)")
    }

    private func collectHosts(from data: LayoutNodeData, into set: inout Set<UUID>) {
        switch data {
        case let .pane(pane):
            if let hid = pane.hostItemID { set.insert(hid) }
        case let .horizontal(children, _), let .vertical(children, _):
            for child in children { collectHosts(from: child, into: &set) }
        }
    }
}
