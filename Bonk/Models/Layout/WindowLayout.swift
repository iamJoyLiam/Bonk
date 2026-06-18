//
//  WindowLayout.swift
//  Bonk
//
//  Layout manager for split pane operations within a tab.
//

import Foundation

/// Manages the layout tree for a tab, providing split/merge/close operations.
@Observable @MainActor
final class TabLayout {
    /// Root node of the layout tree.
    var root: LayoutNode

    /// Currently active (focused) pane ID.
    var activePaneID: UUID

    init(root: LayoutNode) {
        self.root = root
        self.activePaneID = root.paneID
    }

    // MARK: - Split Operations

    /// Split the active pane horizontally (left-right).
    /// Returns the new pane state.
    @discardableResult
    func splitHorizontal() -> PaneState {
        let newPane = PaneState()
        root = insertSplit(
            into: root,
            targetPaneID: activePaneID,
            direction: .horizontal,
            newPane: newPane,
            insertAfter: true
        )
        activePaneID = newPane.id
        return newPane
    }

    /// Split the active pane vertically (top-bottom).
    /// Returns the new pane state.
    @discardableResult
    func splitVertical() -> PaneState {
        let newPane = PaneState()
        root = insertSplit(
            into: root,
            targetPaneID: activePaneID,
            direction: .vertical,
            newPane: newPane,
            insertAfter: true
        )
        activePaneID = newPane.id
        return newPane
    }

    // MARK: - Close Operations

    /// Close the active pane. Returns true if the pane was closed.
    /// Returns false if it was the last pane (can't close).
    @discardableResult
    func closeActivePane() -> Bool {
        return closePane(id: activePaneID)
    }

    /// Close a specific pane. Returns true if closed, false if last pane.
    @discardableResult
    func closePane(id: UUID) -> Bool {
        let result = removePane(from: root, paneID: id)
        switch result {
        case .empty:
            return false // Pane not found
        case .lastPane:
            return false // Last pane, can't close
        case .updated(let node):
            root = node
            if activePaneID == id {
                activePaneID = node.allPaneIDs.first ?? id
            }
            return true
        }
    }

    // MARK: - Navigation

    /// Move focus to a specific pane.
    func selectPane(_ id: UUID) {
        guard root.findPane(id: id) != nil else { return }
        activePaneID = id
    }

    /// Check if a pane exists in the layout.
    func containsPane(_ id: UUID) -> Bool {
        root.findPane(id: id) != nil
    }

    /// Find a pane by ID.
    func findPane(id: UUID) -> PaneState? {
        root.findPane(id: id)
    }

    // MARK: - Private Helpers

    enum SplitDirection {
        case horizontal, vertical
    }

    /// Insert a split containing a new pane next to the target pane.
    private func insertSplit(
        into node: LayoutNode,
        targetPaneID: UUID,
        direction: SplitDirection,
        newPane: PaneState,
        insertAfter: Bool
    ) -> LayoutNode {
        switch node {
        case .pane(let state):
            guard state.id == targetPaneID else { return node }
            let children: [LayoutNode] = insertAfter
                ? [.pane(state), .pane(newPane)]
                : [.pane(newPane), .pane(state)]
            switch direction {
            case .horizontal: return .horizontal(children: children)
            case .vertical: return .vertical(children: children)
            }

        case .horizontal(let children):
            var newChildren = children
            var found = false
            for i in 0..<newChildren.count {
                let updated = insertSplit(
                    into: newChildren[i],
                    targetPaneID: targetPaneID,
                    direction: direction,
                    newPane: newPane,
                    insertAfter: insertAfter
                )
                if updated != newChildren[i] {
                    newChildren[i] = updated
                    found = true
                    break
                }
            }
            return found ? .horizontal(children: newChildren) : node

        case .vertical(let children):
            var newChildren = children
            var found = false
            for i in 0..<newChildren.count {
                let updated = insertSplit(
                    into: newChildren[i],
                    targetPaneID: targetPaneID,
                    direction: direction,
                    newPane: newPane,
                    insertAfter: insertAfter
                )
                if updated != newChildren[i] {
                    newChildren[i] = updated
                    found = true
                    break
                }
            }
            return found ? .vertical(children: newChildren) : node
        }
    }

    enum RemoveResult {
        case empty                    // Pane not found
        case lastPane                 // Only one pane left, can't remove
        case updated(LayoutNode)      // Successfully removed
    }

    /// Remove a pane from the tree, collapsing single-child containers.
    private func removePane(from node: LayoutNode, paneID: UUID) -> RemoveResult {
        switch node {
        case .pane(let state):
            guard state.id == paneID else { return .empty }
            return .lastPane // Will be handled by caller

        case .horizontal(let children), .vertical(let children):
            var newChildren: [LayoutNode] = []
            var removed = false

            for child in children {
                let result = removePane(from: child, paneID: paneID)
                switch result {
                case .empty:
                    newChildren.append(child)
                case .lastPane:
                    // This is the pane to close, don't add it
                    removed = true
                case .updated(let updatedNode):
                    newChildren.append(updatedNode)
                    removed = true
                }
            }

            guard removed else { return .empty }

            // If only one child remains, collapse the container
            if newChildren.count == 1 {
                return .updated(newChildren[0])
            }
            // If no children remain (shouldn't happen), return empty
            if newChildren.isEmpty {
                return .empty
            }

            // Rebuild the container
            switch node {
            case .horizontal:
                return .updated(.horizontal(children: newChildren))
            case .vertical:
                return .updated(.vertical(children: newChildren))
            default:
                return .empty
            }
        }
    }
}
