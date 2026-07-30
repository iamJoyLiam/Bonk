//
//  WorkspaceModels.swift
//  Bonk
//
//  Data models for Workspaces feature.
//

import Foundation
import SwiftData

// MARK: - Workspace Model

/// A saved workspace configuration that can be restored later.
@Model
final class Workspace {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    /// Active tab index when workspace was saved.
    var activeTabIndex: Int

    /// Window geometry (optional).
    var windowWidth: Double?
    var windowHeight: Double?

    /// Tabs in this workspace, ordered by sort order.
    @Relationship(deleteRule: .cascade)
    var tabs: [WorkspaceTab]

    init(
        name: String,
        tabs: [WorkspaceTab] = [],
        activeTabIndex: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.activeTabIndex = activeTabIndex
        self.tabs = tabs
    }
}

// MARK: - WorkspaceTab Model

/// A tab configuration within a workspace.
@Model
final class WorkspaceTab {
    var id: UUID
    var title: String
    var colorLabel: String?
    var sortOrder: Int
    var isBroadcastEnabled: Bool

    /// Reference to the host item (by ID for SwiftData relationship).
    var hostItemID: UUID

    /// Layout snapshot as JSON data.
    var layoutData: Data?

    /// Active pane ID when saved.
    var activePaneID: UUID?

    init(
        hostItemID: UUID,
        title: String,
        colorLabel: String? = nil,
        sortOrder: Int = 0,
        isBroadcastEnabled: Bool = false,
        layoutSnapshot: LayoutSnapshot? = nil,
        activePaneID: UUID? = nil
    ) {
        self.id = UUID()
        self.hostItemID = hostItemID
        self.title = title
        self.colorLabel = colorLabel
        self.sortOrder = sortOrder
        self.isBroadcastEnabled = isBroadcastEnabled
        self.activePaneID = activePaneID

        if let snapshot = layoutSnapshot,
           let data = try? JSONEncoder().encode(snapshot)
        {
            self.layoutData = data
        }
    }

    /// Decode the layout snapshot from stored data.
    func decodeLayout() -> LayoutSnapshot? {
        guard let data = layoutData else { return nil }
        return try? JSONDecoder().decode(LayoutSnapshot.self, from: data)
    }
}

// MARK: - Layout Snapshot (Codable)

/// A codable representation of the layout tree for persistence.
struct LayoutSnapshot: Codable {
    enum NodeType: String, Codable {
        case pane
        case horizontal
        case vertical
    }

    let nodeType: NodeType
    let paneID: UUID?
    let hostItemID: UUID?
    let children: [LayoutSnapshot]?

    /// Create a snapshot from a LayoutNode.
    static func from(_ node: LayoutNode) -> LayoutSnapshot {
        switch node {
        case let .pane(paneState):
            return LayoutSnapshot(
                nodeType: .pane,
                paneID: paneState.id,
                hostItemID: nil,
                children: nil
            )
        case let .horizontal(children):
            return LayoutSnapshot(
                nodeType: .horizontal,
                paneID: nil,
                hostItemID: nil,
                children: children.map { LayoutSnapshot.from($0) }
            )
        case let .vertical(children):
            return LayoutSnapshot(
                nodeType: .vertical,
                paneID: nil,
                hostItemID: nil,
                children: children.map { LayoutSnapshot.from($0) }
            )
        }
    }
}

// MARK: - Workspace Creation Helper

extension Workspace {
    /// Create a workspace from current SessionManager state.
    @MainActor
    static func from(
        sessionManager: SessionManager,
        name: String
    ) -> Workspace {
        var workspaceTabs: [WorkspaceTab] = []

        for (index, tab) in sessionManager.tabs.enumerated() {
            let layoutSnapshot = LayoutSnapshot.from(tab.layout.root)
            let workspaceTab = WorkspaceTab(
                hostItemID: tab.hostItem.id,
                title: tab.title,
                colorLabel: tab.colorLabel,
                sortOrder: index,
                isBroadcastEnabled: tab.isBroadcastEnabled,
                layoutSnapshot: layoutSnapshot,
                activePaneID: tab.activePaneID
            )
            workspaceTabs.append(workspaceTab)
        }

        let activeIndex = sessionManager.tabs.firstIndex { $0.id == sessionManager.activeTabID } ?? 0

        return Workspace(
            name: name,
            tabs: workspaceTabs,
            activeTabIndex: activeIndex
        )
    }
}
