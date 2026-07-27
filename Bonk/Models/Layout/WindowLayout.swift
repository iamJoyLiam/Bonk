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
        activePaneID = root.paneState?.id ?? UUID()
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

    /// Insert a new pane at a specific position (used for drag-to-split).
    /// - Parameters:
    ///   - direction: .horizontal (left-right) or .vertical (top-bottom)
    ///   - position: The position relative to the active pane (.left/.top = before, .right/.bottom = after)
    @discardableResult
    func insertPane(direction: SplitDirection, at position: PaneInsertPosition) -> PaneState {
        let newPane = PaneState()
        root = insertSplit(
            into: root,
            targetPaneID: activePaneID,
            direction: direction,
            newPane: newPane,
            at: position
        )
        activePaneID = newPane.id
        return newPane
    }

    /// Pane insertion position relative to the target pane.
    enum PaneInsertPosition {
        case before  // left or top
        case after   // right or bottom
    }

    /// Split direction for pane operations.
    enum SplitDirection {
        case horizontal, vertical

        func makeContainer(children: [LayoutNode]) -> LayoutNode {
            switch self {
            case .horizontal: .horizontal(children: children)
            case .vertical: .vertical(children: children)
            }
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
        case let .updated(node):
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

    /// Generic split method to avoid code duplication.
    private func split(direction: SplitDirection) -> PaneState {
        insertPane(direction: direction, at: .after)
    }

    /// Insert a split containing a new pane next to the target pane.
    private func insertSplit(
        into node: LayoutNode,
        targetPaneID: UUID,
        direction: SplitDirection,
        newPane: PaneState,
        at position: PaneInsertPosition
    ) -> LayoutNode {
        switch node {
        case let .pane(state):
            guard state.id == targetPaneID else { return node }
            let children: [LayoutNode] = position == .before
                ? [.pane(newPane), .pane(state)]
                : [.pane(state), .pane(newPane)]
            return direction.makeContainer(children: children)

        case let .horizontal(children), let .vertical(children):
            var newChildren = children
            for index in 0 ..< newChildren.count {
                let updated = insertSplit(
                    into: newChildren[index],
                    targetPaneID: targetPaneID,
                    direction: direction,
                    newPane: newPane,
                    at: position
                )
                if updated != newChildren[index] {
                    newChildren[index] = updated
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
        case let .pane(state):
            return state.id == paneID ? .lastPane : .empty

        case let .horizontal(children), let .vertical(children):
            var newChildren: [LayoutNode] = []
            var removed = false

            for child in children {
                let result = removePane(from: child, paneID: paneID)
                switch result {
                case .empty:
                    newChildren.append(child)
                case .lastPane:
                    removed = true
                case let .updated(updatedNode):
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
