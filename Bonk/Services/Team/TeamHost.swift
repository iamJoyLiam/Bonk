//
//  TeamHost.swift
//  Bonk
//
//  Host peer for Team sharing (Phase 4).
//  Owns broadcast, replay, heartbeat for host role.
//

import Foundation
import Network
import os

@MainActor
final class TeamHost: ObservableObject {
    @Published var sharedSessionID: TeamSessionID?
    @Published var connectedPeers: [TeamPeer] = []

    private let store: TeamStore
    private let sessionManager: SessionManager

    init(store: TeamStore, sessionManager: SessionManager) {
        self.store = store
        self.sessionManager = sessionManager
    }

    func broadcastOutput(_ text: String, sessionID: TeamSessionID) {
        // Will be wired to Engine tick in Phase 4.2
    }
}
