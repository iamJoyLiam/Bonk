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
    /// Horizontal split (left-right layout). `fraction` is the portion of
    /// the container taken by the FIRST child (0.15...0.85), adjustable by
    /// dragging the divider.
    case horizontal(children: [LayoutNode], fraction: CGFloat)
    /// Vertical split (top-bottom layout). `fraction` is the portion of the
    /// container taken by the FIRST child.
    case vertical(children: [LayoutNode], fraction: CGFloat)

    /// Default split proportion for a new container (50/50).
    static let defaultFraction: CGFloat = 0.5

    /// Clamp a fraction to the draggable range.
    static func clampedFraction(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.15), 0.85)
    }

    /// Stable identity for SwiftUI diffing.
    /// Container nodes use a hash of children IDs.
    var id: UUID {
        switch self {
        case let .pane(state):
            state.id
        case let .horizontal(children, _):
            LayoutNode.stableID(for: children, prefix: "h")
        case let .vertical(children, _):
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
        case let .horizontal(children, _), let .vertical(children, _):
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
        case let .horizontal(children, _), let .vertical(children, _):
            children.flatMap(\.allPaneIDs)
        }
    }

    /// Count total panes in this tree.
    var paneCount: Int {
        switch self {
        case .pane: 1
        case let .horizontal(children, _), let .vertical(children, _):
            children.reduce(0) { $0 + $1.paneCount }
        }
    }

    // MARK: - Private

    /// Generate a deterministic UUID for container nodes based on children.
    /// Uses FNV-1a (not String.hashValue, which is randomly seeded per
    /// process and truncated to 32 bits): the same layout must yield the same
    /// container ID across launches, and 64 bits keep collisions negligible.
    private static func stableID(for children: [LayoutNode], prefix: String) -> UUID {
        var bytes = Array(prefix.utf8)
        for child in children {
            bytes.append(contentsOf: Array(child.id.uuidString.utf8))
        }
        // Two FNV-1a passes with different seeds fill the 128-bit UUID
        // deterministically (28 hash hex digits + fixed version/variant nibble).
        let h1 = fnv1a(bytes, seed: 0xcbf29ce484222325)
        let h2 = fnv1a(bytes, seed: 0x84222325cbf29ce4)
        let uuidString = String(
            format: "%08x-%04x-%04x-%04x-%012llx",
            UInt32(truncatingIfNeeded: h1),
            UInt16(truncatingIfNeeded: h1 >> 32),
            UInt16(truncatingIfNeeded: h1 >> 48) | 0x4000,
            UInt16(truncatingIfNeeded: h2),
            UInt64(truncatingIfNeeded: h2 >> 16)
        )
        return UUID(uuidString: uuidString) ?? UUID()
    }

    /// FNV-1a 64-bit hash (deterministic across launches).
    private static func fnv1a(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

// MARK: - Equatable

extension LayoutNode: Equatable {
    static func == (lhs: LayoutNode, rhs: LayoutNode) -> Bool {
        switch (lhs, rhs) {
        case let (.pane(leftState), .pane(rightState)):
            leftState.id == rightState.id
        case let (.horizontal(leftChildren, leftFraction), .horizontal(rightChildren, rightFraction)):
            leftChildren == rightChildren && leftFraction == rightFraction
        case let (.vertical(leftChildren, leftFraction), .vertical(rightChildren, rightFraction)):
            leftChildren == rightChildren && leftFraction == rightFraction
        default:
            false
        }
    }
}
