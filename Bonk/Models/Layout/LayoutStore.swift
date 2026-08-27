//
//  LayoutStore.swift
//  Bonk
//
//  Single source of truth for layout tree (Phase 5).
//  Replaces LayoutNode / LayoutNodeData / TabLayout triple.
//

import Foundation

@MainActor
final class LayoutStore: ObservableObject {
    @Published var root: LayoutNode = .leaf(PaneState())

    func codableRepresentation() -> Data? {
        try? JSONEncoder().encode(CodableLayoutNode(node: root))
    }

    private struct CodableLayoutNode: Codable {
        let node: LayoutNode
        init(node: LayoutNode) { self.node = node }
        // Placeholder: real Codable will mirror LayoutNode directly
        func encode(to encoder: Encoder) throws {}
        init(from decoder: Decoder) throws { self.node = .leaf(PaneState()) }
    }
}
