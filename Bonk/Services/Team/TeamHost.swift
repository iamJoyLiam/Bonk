//
//  TeamHost.swift
//  Bonk
//
//  Host peer for Team sharing (Phase 4).
//  Owns broadcast, replay, heartbeat for host role. Single pane constraint via TeamStore.HostSession.
//  SessionManager injected (no BonkAppDelegate cycle).
//

import Combine
import Foundation
import Network
import os

@MainActor
final class TeamHost: ObservableObject {
    @Published var sharedSessionID: TeamSessionID?
    @Published var connectedPeers: [TeamPeer] = []

    private let store: TeamStore
    private let sessionManager: SessionManager
    private let logger = Logger(subsystem: "com.bonk", category: "TeamHost")
    private var cancellables = Set<AnyCancellable>()

    init(store: TeamStore = .shared, sessionManager: SessionManager) {
        self.store = store
        self.sessionManager = sessionManager
        // Keep Host's sharedSessionID in sync with Store's single HostSession
        store.$hostSession
            .map { $0?.teamID }
            .receive(on: DispatchQueue.main)
            .assign(to: &$sharedSessionID)
    }

    // MARK: - HostSession (1 pane) constraint

    func setSharedPane(tabID: UUID, paneID: UUID) {
        store.setHostSession(tabID: tabID, paneID: paneID)
        logger.info("[Host] setSharedPane \(paneID.uuidString.prefix(8))")
    }

    func clearSharedPane() {
        store.clearHostSession()
        logger.info("[Host] clearSharedPane")
    }

    // MARK: - Broadcast (called from TerminalEngine tick)

    func broadcastOutput(_ text: String, sessionID: TeamSessionID) {
        // Enforce single pane: ignore output for non-hostSession pane
        if let host = store.hostSession, host.teamID != sessionID { return }
        // Delegate to Relay for now (Relay owns framing/replay). Host owns the decision.
        TeamRelay.shared.broadcastOutput(text, sessionID: sessionID)
    }

    // MARK: - Control (via injected SessionManager, no cycle)

    func grantControl(to peerID: UUID) {
        TeamRelay.shared.grantControl(to: peerID)
    }

    func forwardInput(_ text: String, to sessionID: TeamSessionID) {
        let bytes = Array(text.utf8)
        Task { [sessionManager] in
            try? await sessionManager.sendInput(bytes[...], to: sessionID.tabID, paneID: sessionID.paneID)
        }
    }
}
