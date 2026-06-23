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

    /// Stable identity for SwiftUI diffing.
    /// Container nodes use a hash of children IDs.
    var id: UUID {
        switch self {
        case let .pane(state):
            state.id
        case let .horizontal(children):
            LayoutNode.stableID(for: children, prefix: "h")
        case let .vertical(children):
            LayoutNode.stableID(for: children, prefix: "v")
        }
    }

    /// Whether this node is a leaf (pane).
    var isPane: Bool {
        if case .pane = self { return true }
        return false
    }

    /// Get the pane state if this is a leaf node.
    var paneState: PaneState? {
        if case let .pane(state) = self { return state }
        return nil
    }

    /// Find a pane by ID in this tree.
    func findPane(id: UUID) -> PaneState? {
        switch self {
        case let .pane(state):
            return state.id == id ? state : nil
        case let .horizontal(children), let .vertical(children):
            for child in children {
                if let found = child.findPane(id: id) { return found }
            }
            return nil
        }
    }

    /// Get all pane IDs in this tree.
    var allPaneIDs: [UUID] {
        switch self {
        case let .pane(state): [state.id]
        case let .horizontal(children), let .vertical(children):
            children.flatMap(\.allPaneIDs)
        }
    }

    /// Count total panes in this tree.
    var paneCount: Int {
        switch self {
        case .pane: 1
        case let .horizontal(children), let .vertical(children):
            children.reduce(0) { $0 + $1.paneCount }
        }
    }

    // MARK: - Private

    /// Generate a stable UUID for container nodes based on children.
    private static func stableID(for children: [LayoutNode], prefix: String) -> UUID {
        let childIDs = children.map(\.id.uuidString).joined(separator: "-")
        let hash = "\(prefix):\(childIDs)".hashValue
        // Use a deterministic UUID based on hash
        let hashValue = Int32(truncatingIfNeeded: hash)
        let uuidString = String(
            format: "%08x-0000-0000-0000-000000000000",
            UInt32(bitPattern: hashValue)
        )
        return UUID(uuidString: uuidString) ?? UUID()
    }
}

// MARK: - Equatable

extension LayoutNode: Equatable {
    static func == (lhs: LayoutNode, rhs: LayoutNode) -> Bool {
        switch (lhs, rhs) {
        case let (.pane(leftState), .pane(rightState)):
            return leftState.id == rightState.id
        case let (.horizontal(leftChildren), .horizontal(rightChildren)):
            return leftChildren == rightChildren
        case let (.vertical(leftChildren), .vertical(rightChildren)):
            return leftChildren == rightChildren
        default:
            return false
        }
    }
}
