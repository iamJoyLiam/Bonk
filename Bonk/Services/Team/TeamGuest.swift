//
//  TeamGuest.swift
//  Bonk
//
//  Guest peer for Team sharing (Phase 4).
//  Owns input, heartbeat, pairing for guest role.
//

import Foundation
import Network
import os

@MainActor
final class TeamGuest: ObservableObject {
    @Published var isConnected = false
    @Published var hostPeerID: UUID?

    private let store: TeamStore

    init(store: TeamStore) {
        self.store = store
    }

    func connect(to endpoint: NWEndpoint, displayName: String, pin: String) {
        // Will be wired to NWConnection in Phase 4.2
    }

    func disconnect() {
        isConnected = false
        hostPeerID = nil
    }
}
