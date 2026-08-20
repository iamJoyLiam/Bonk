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
            let weights = Array(
                repeating: LayoutNode.defaultWeight,
                count: max(children.count, 1)
            )
            switch self {
            case .horizontal:
                return LayoutNode.horizontal(children: children, weights: weights)
            case .vertical:
                return LayoutNode.vertical(children: children, weights: weights)
            }
        }
    }

    // MARK: - Resize Operations

    /// Adjust the split proportion of a container. Called while the user
    /// drags the divider at `dividerIndex` (between children at that index
    /// and index+1). ONLY those two children change — panes beyond the
    /// divider keep their size, which is what users expect with 3+ panes.
    /// `normalizedDelta` is the drag movement as a fraction of the container
    /// size (-1...1).
    func setFraction(_ normalizedDelta: CGFloat, containerID: UUID, dividerIndex: Int) {
        root = adjustWeights(
            in: root,
            containerID: containerID,
            dividerIndex: dividerIndex,
            normalizedDelta: normalizedDelta
        )
    }

    /// Recursively find the container matching `containerID` and adjust the
    /// weights of its two children adjacent to `dividerIndex`.
    private func adjustWeights(
        in node: LayoutNode,
        containerID: UUID,
        dividerIndex: Int,
        normalizedDelta: CGFloat
    ) -> LayoutNode {
        switch node {
        case .pane:
            return node
        case let .horizontal(children, weights):
            if node.id == containerID {
                return .horizontal(
                    children: children,
                    weights: Self.adjustedWeights(
                        weights: weights,
                        dividerIndex: dividerIndex,
                        normalizedDelta: normalizedDelta
                    )
                )
            }
            let updated = children.map {
                adjustWeights(
                    in: $0,
                    containerID: containerID,
                    dividerIndex: dividerIndex,
                    normalizedDelta: normalizedDelta
                )
            }
            return .horizontal(children: updated, weights: weights)
        case let .vertical(children, weights):
            if node.id == containerID {
                return .vertical(
                    children: children,
                    weights: Self.adjustedWeights(
                        weights: weights,
                        dividerIndex: dividerIndex,
                        normalizedDelta: normalizedDelta
                    )
                )
            }
            let updated = children.map {
                adjustWeights(
                    in: $0,
                    containerID: containerID,
                    dividerIndex: dividerIndex,
                    normalizedDelta: normalizedDelta
                )
            }
            return .vertical(children: updated, weights: weights)
        }
    }

    /// Move share from child `dividerIndex+1` to child `dividerIndex`
    /// (positive delta) or the other way, clamped so no child drops below
    /// `minWeightFraction` of the total. The total share is conserved.
    private static func adjustedWeights(
        weights: [CGFloat],
        dividerIndex: Int,
        normalizedDelta: CGFloat
    ) -> [CGFloat] {
        guard dividerIndex >= 0, dividerIndex + 1 < weights.count else { return weights }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights }
        let minShare = sum * LayoutNode.minWeightFraction

        var newWeights = weights
        var first = newWeights[dividerIndex] + normalizedDelta * sum
        var second = newWeights[dividerIndex + 1] - normalizedDelta * sum
        first = min(max(first, minShare), sum - minShare)
        second = sum - first
        // Re-normalize so the total stays exactly sum.
        newWeights[dividerIndex] = first
        newWeights[dividerIndex + 1] = second
        return newWeights
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

        case let .horizontal(children, weights), let .vertical(children, weights):
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
                    // Preserve original container type; grow the weights with
                    // the default share for the newly inserted child.
                    var newWeights = weights
                    if newWeights.count < newChildren.count {
                        newWeights.append(LayoutNode.defaultWeight)
                    }
                    switch node {
                    case .horizontal: return .horizontal(children: newChildren, weights: newWeights)
                    case .vertical: return .vertical(children: newChildren, weights: newWeights)
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

        case let .horizontal(children, weights), let .vertical(children, weights):
            var newChildren: [LayoutNode] = []
            var newWeights: [CGFloat] = []
            var removed = false

            for (childIndex, child) in children.enumerated() {
                let result = removePane(from: child, paneID: paneID)
                switch result {
                case .empty:
                    newChildren.append(child)
                    if childIndex < weights.count {
                        newWeights.append(weights[childIndex])
                    }
                case .lastPane:
                    removed = true
                case let .updated(updatedNode):
                    newChildren.append(updatedNode)
                    if childIndex < weights.count {
                        newWeights.append(weights[childIndex])
                    }
                    removed = true
                }
            }

            guard removed else { return .empty }

            // Collapse single-child containers (weights become meaningless)
            if newChildren.count == 1 {
                return .updated(newChildren[0])
            }
            if newChildren.isEmpty {
                return .empty
            }

            // Rebuild container preserving original type; keep the weights
            // aligned with the surviving children.
            if newWeights.count < newChildren.count {
                newWeights.append(LayoutNode.defaultWeight)
            }
            switch node {
            case .horizontal: return .updated(.horizontal(children: newChildren, weights: newWeights))
            case .vertical: return .updated(.vertical(children: newChildren, weights: newWeights))
            default: return .empty
            }
        }
    }
}
