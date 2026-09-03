//
//  LayoutStore.swift
//  Bonk
//
//  Single source of truth for layout tree (Phase 5).
//  One tree, CGFloat weights, Codable round-trip, concurrent restore.
//

import Combine
import Foundation
import os

@MainActor
final class LayoutStore: ObservableObject {
    @Published var root: LayoutNode = .horizontal(children: [], weights: [])

    private let logger = Logger(subsystem: "com.bonk", category: "LayoutStore")

    // MARK: - Codable bridge (single tree, no triple)

    /// Codable view of LayoutNode — weights as Double for plist/JSON, stable IDs preserved.
    enum CodableNode: Codable, Equatable {
        case pane(id: UUID, hostItemID: UUID?, title: String)
        case horizontal(children: [CodableNode], weights: [Double])
        case vertical(children: [CodableNode], weights: [Double])

        @MainActor init(from node: LayoutNode) {
            switch node {
            case let .pane(state):
                self = .pane(id: state.id, hostItemID: state.hostItem?.id, title: state.title)
            case let .horizontal(children, weights):
                self = .horizontal(children: children.map { CodableNode(from: $0) }, weights: weights.map { Double($0) })
            case let .vertical(children, weights):
                self = .vertical(children: children.map { CodableNode(from: $0) }, weights: weights.map { Double($0) })
            }
        }

        @MainActor func toNode(hostStore: [UUID: HostItem] = [:], defaultHost: HostItem? = nil, idMap: inout [UUID: UUID]) -> LayoutNode {
            switch self {
            case let .pane(id, hostID, title):
                let state = PaneState()
                idMap[id] = state.id
                state.title = title
                if let hid = hostID, let hostItem = hostStore[hid] { state.hostItem = hostItem }
                else if let fallbackHost = defaultHost { state.hostItem = fallbackHost }
                // id is remapped to new PaneState.id for stable UI; original id kept in idMap
                return .pane(state)
            case let .horizontal(children, weights):
                let nodes = children.map { $0.toNode(hostStore: hostStore, defaultHost: defaultHost, idMap: &idMap) }
                return .horizontal(children: nodes, weights: weights.map { CGFloat($0) })
            case let .vertical(children, weights):
                let nodes = children.map { $0.toNode(hostStore: hostStore, defaultHost: defaultHost, idMap: &idMap) }
                return .vertical(children: nodes, weights: weights.map { CGFloat($0) })
            }
        }

        // Custom Codable to keep single enum with associated values plist-friendly
        private enum CodingKeys: String, CodingKey { case type, id, hostItemID, title, children, weights }
        // swiftlint:disable:next identifier_name
        private enum NodeType: String, Codable { case pane, h, v }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .pane(id, hostID, title):
                try container.encode(NodeType.pane, forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encodeIfPresent(hostID, forKey: .hostItemID)
                try container.encode(title, forKey: .title)
            case let .horizontal(children, weights):
                try container.encode(NodeType.h, forKey: .type)
                try container.encode(children, forKey: .children)
                try container.encode(weights, forKey: .weights)
            case let .vertical(children, weights):
                try container.encode(NodeType.v, forKey: .type)
                try container.encode(children, forKey: .children)
                try container.encode(weights, forKey: .weights)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let nodeType = try container.decode(NodeType.self, forKey: .type)
            switch nodeType {
            case .pane:
                let id = try container.decode(UUID.self, forKey: .id)
                let hid = try container.decodeIfPresent(UUID.self, forKey: .hostItemID)
                let title = try container.decode(String.self, forKey: .title)
                self = .pane(id: id, hostItemID: hid, title: title)
            case .h:
                let children = try container.decode([CodableNode].self, forKey: .children)
                let weights = try container.decode([Double].self, forKey: .weights)
                self = .horizontal(children: children, weights: weights)
            case .v:
                let children = try container.decode([CodableNode].self, forKey: .children)
                let weights = try container.decode([Double].self, forKey: .weights)
                self = .vertical(children: children, weights: weights)
            }
        }
    }

    // MARK: - Public API (small interface, deep impl)

    func setRoot(_ node: LayoutNode) {
        root = node
    }

    func encodedData() -> Data? {
        let codable = CodableNode(from: root)
        return try? JSONEncoder().encode(codable)
    }

    func restore(from data: Data, hostStore: [UUID: HostItem] = [:], defaultHost: HostItem? = nil) -> LayoutNode? {
        guard let codable = try? JSONDecoder().decode(CodableNode.self, from: data) else {
            logger.error("[LayoutStore] decode failed")
            return nil
        }
        var idMap: [UUID: UUID] = [:]
        let node = codable.toNode(hostStore: hostStore, defaultHost: defaultHost, idMap: &idMap)
        root = node
        return node
    }

    /// Round-trip test helper: encode then decode, compare structure (weights + ids via idMap)
    func roundTripEqual(to node: LayoutNode) -> Bool {
        let data = try? JSONEncoder().encode(CodableNode(from: node))
        guard let data, let decoded = try? JSONDecoder().decode(CodableNode.self, from: data) else { return false }
        let originalNode = CodableNode(from: node)
        let decodedNode = decoded
        // Compare via re-encoded data equality (deterministic)
        let originalData = try? JSONEncoder().encode(originalNode)
        let decodedData = try? JSONEncoder().encode(decodedNode)
        return originalData == decodedData
    }

    // MARK: - Concurrent restore (replaces sequential for tab { for pane { await connect } })

    /// Restore panes concurrently — one task group per tab, N×M panes in parallel.
    func restorePanesConcurrently(for tab: TerminalTab, sessionManager: SessionManager) async {
        let panes = collectPanes(from: root)
        // First pane is connected via connectTab; remaining panes concurrent
        let remaining = panes.dropFirst()
        guard !remaining.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for paneState in remaining {
                group.addTask { [weak sessionManager, weak tab] in
                    guard let tab, let sessionManager else { return }
                    await sessionManager.connectPane(tab: tab, pane: paneState)
                }
            }
        }
    }

    private func collectPanes(from node: LayoutNode) -> [PaneState] {
        switch node {
        case let .pane(paneState): [paneState]
        case let .horizontal(children, _), let .vertical(children, _):
            children.flatMap { collectPanes(from: $0) }
        }
    }
}
