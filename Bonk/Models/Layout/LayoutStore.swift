//
//  LayoutStore.swift
//  Bonk
//
//  Single source of truth for layout tree (Phase 5).
//  Replaces LayoutNode / LayoutNodeData / TabLayout triple.
//

import Combine
import Foundation

@MainActor
final class LayoutStore: ObservableObject {
    @Published var root: LayoutNode = .horizontal(children: [], weights: [])

    func codableRepresentation() -> Data? {
        // Placeholder: real Codable will mirror LayoutNode directly (weights CGFloat, stable IDs)
        return nil
    }

    func restore(from data: Data) {
        // Placeholder: decode single tree, validate weights, concurrent restore
    }
}
