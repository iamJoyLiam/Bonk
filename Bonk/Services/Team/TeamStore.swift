//
//  TeamStore.swift
//  Bonk
//
//  Single source of truth for Team isHosting + discovery (Phase 4).
//  Replaces dual NWListener isHosting divergence.
//

import Combine
import Foundation
import Network

@MainActor
final class TeamStore: ObservableObject {
    @Published var isHosting = false
    @Published var hostedPort: UInt16?
    @Published var lastError: String?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    func startHosting(displayName: String, serviceType: String) throws {
        let params = NWParameters.tcp
        listener = try NWListener(service: .init(name: displayName, type: serviceType), using: params)
        listener?.start(queue: .global(qos: .utility))
        isHosting = true
    }

    func stopHosting() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        isHosting = false
        hostedPort = nil
    }
}
