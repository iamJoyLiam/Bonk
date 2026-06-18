//
//  LayoutNode.swift
//  Bonk
//
//  Recursive layout tree for split pane management within a tab.
//

import Foundation

/// A node in the layout tree — either a pane or a split container.
indirect enum LayoutNode: Identifiable {
    /// A leaf node containing a pane with its own terminal instance.
    case pane(PaneState)
    /// Horizontal split (left-right layout).
    case horizontal(children: [LayoutNode])
    /// Vertical split (top-bottom layout).
    case vertical(children: [LayoutNode])

    var id: UUID {
        switch self {
        case .pane(let state): state.id
        case .horizontal: UUID()
        case .vertical: UUID()
        }
    }

    /// Get the pane ID if this is a leaf node.
    var paneID: UUID {
        switch self {
        case .pane(let state): state.id
        case .horizontal, .vertical: UUID()
        }
    }

    /// Whether this node is a leaf (pane).
    var isPane: Bool {
        if case .pane = self { return true }
        return false
    }

    /// Get the pane state if this is a leaf node.
    var paneState: PaneState? {
        if case .pane(let state) = self { return state }
        return nil
    }

    /// Find a pane by ID in this tree.
    func findPane(id: UUID) -> PaneState? {
        switch self {
        case .pane(let state):
            return state.id == id ? state : nil
        case .horizontal(let children), .vertical(let children):
            for child in children {
                if let found = child.findPane(id: id) { return found }
            }
            return nil
        }
    }

    /// Find the node containing a specific pane ID.
    func findNode(containing paneID: UUID) -> LayoutNode? {
        switch self {
        case .pane(let state):
            return state.id == paneID ? self : nil
        case .horizontal(let children), .vertical(let children):
            for child in children {
                if let found = child.findNode(containing: paneID) { return found }
            }
            return nil
        }
    }

    /// Get all pane IDs in this tree.
    var allPaneIDs: [UUID] {
        switch self {
        case .pane(let state): [state.id]
        case .horizontal(let children), .vertical(let children):
            children.flatMap { $0.allPaneIDs }
        }
    }

    /// Count total panes in this tree.
    var paneCount: Int {
        switch self {
        case .pane: 1
        case .horizontal(let children), .vertical(let children):
            children.reduce(0) { $0 + $1.paneCount }
        }
    }
}

// MARK: - Equatable

extension LayoutNode: Equatable {
    static func == (lhs: LayoutNode, rhs: LayoutNode) -> Bool {
        switch (lhs, rhs) {
        case (.pane(let l), .pane(let r)): l.id == r.id
        case (.horizontal(let lc), .horizontal(let rc)): lc == rc
        case (.vertical(let lc), .vertical(let rc)): lc == rc
        default: false
        }
    }
}
