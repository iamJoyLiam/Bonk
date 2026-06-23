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
        self.activePaneID = root.paneState?.id ?? UUID()
    }

    // MARK: - Split Operations

    /// Split the active pane horizontally (left-right).
    @discardableResult
    func splitHorizontal() -> PaneState {
        split(direction: .horizontal)
    }

    /// Split the active pane vertically (top-bottom).
    @discardableResult
    func splitVertical() -> PaneState {
        split(direction: .vertical)
    }

    /// Swap the order of panes in the root container.
    /// Used to adjust pane order after drag-to-split.
    func swapPanes() {
        root = swapPanes(in: root)
    }

    /// Recursively swap panes in a container.
    private func swapPanes(in node: LayoutNode) -> LayoutNode {
        switch node {
        case .pane:
            return node
        case .horizontal(let children):
            let swapped = children.reversed()
            return .horizontal(children: Array(swapped))
        case .vertical(let children):
            let swapped = children.reversed()
            return .vertical(children: Array(swapped))
        }
    }

    // MARK: - Close Operations

    /// Close the active pane. Returns true if closed, false if last pane.
    @discardableResult
    func closeActivePane() -> Bool {
        closePane(id: activePaneID)
    }

    /// Close a specific pane. Returns true if closed, false if last pane.
    @discardableResult
    func closePane(id: UUID) -> Bool {
        let result = removePane(from: root, paneID: id)
        switch result {
        case .empty, .lastPane:
            return false
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

    /// Find a pane by ID.
    func findPane(id: UUID) -> PaneState? {
        root.findPane(id: id)
    }

    // MARK: - Private

    private enum SplitDirection {
        case horizontal, vertical

        func makeContainer(children: [LayoutNode]) -> LayoutNode {
            switch self {
            case .horizontal: return .horizontal(children: children)
            case .vertical: return .vertical(children: children)
            }
        }
    }

    /// Generic split method to avoid code duplication.
    private func split(direction: SplitDirection) -> PaneState {
        let newPane = PaneState()
        root = insertSplit(
            into: root,
            targetPaneID: activePaneID,
            direction: direction,
            newPane: newPane
        )
        activePaneID = newPane.id
        return newPane
    }

    /// Insert a split containing a new pane next to the target pane.
    private func insertSplit(
        into node: LayoutNode,
        targetPaneID: UUID,
        direction: SplitDirection,
        newPane: PaneState
    ) -> LayoutNode {
        switch node {
        case .pane(let state):
            guard state.id == targetPaneID else { return node }
            return direction.makeContainer(children: [.pane(state), .pane(newPane)])

        case .horizontal(let children), .vertical(let children):
            var newChildren = children
            for i in 0..<newChildren.count {
                let updated = insertSplit(
                    into: newChildren[i],
                    targetPaneID: targetPaneID,
                    direction: direction,
                    newPane: newPane
                )
                if updated != newChildren[i] {
                    newChildren[i] = updated
                    // Preserve original container type
                    switch node {
                    case .horizontal: return .horizontal(children: newChildren)
                    case .vertical: return .vertical(children: newChildren)
                    default: return node
                    }
                }
            }
            return node
        }
    }

    private enum RemoveResult {
        case empty
        case lastPane
        case updated(LayoutNode)
    }

    /// Remove a pane from the tree, collapsing single-child containers.
    private func removePane(from node: LayoutNode, paneID: UUID) -> RemoveResult {
        switch node {
        case .pane(let state):
            return state.id == paneID ? .lastPane : .empty

        case .horizontal(let children), .vertical(let children):
            var newChildren: [LayoutNode] = []
            var removed = false

            for child in children {
                let result = removePane(from: child, paneID: paneID)
                switch result {
                case .empty:
                    newChildren.append(child)
                case .lastPane:
                    removed = true
                case .updated(let updatedNode):
                    newChildren.append(updatedNode)
                    removed = true
                }
            }

            guard removed else { return .empty }

            // Collapse single-child containers
            if newChildren.count == 1 {
                return .updated(newChildren[0])
            }
            if newChildren.isEmpty {
                return .empty
            }

            // Rebuild container preserving original type
            switch node {
            case .horizontal: return .updated(.horizontal(children: newChildren))
            case .vertical: return .updated(.vertical(children: newChildren))
            default: return .empty
            }
        }
    }
}
