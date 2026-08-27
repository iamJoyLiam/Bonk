//
//  TeamGuest.swift
//  Bonk
//
//  Guest peer for Team sharing (Phase 4).
//  Owns input, heartbeat, pairing for guest role. Store injected, no cycle.
//

import Combine
import Foundation
import Network
import os

@MainActor
final class TeamGuest: ObservableObject {
    @Published var isConnected = false
    @Published var hostPeerID: UUID?
    @Published var lastError: String?

    private let store: TeamStore
    private let logger = Logger(subsystem: "com.bonk", category: "TeamGuest")
    private var connection: NWConnection?
    private var heartbeatTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(store: TeamStore = .shared) {
        self.store = store
        // Mirror Store's isHosting so Guest knows host state (single truth)
        store.$isHosting.receive(on: DispatchQueue.main).sink { [weak self] _ in
            // isHosting true → guest should not be browsing
        }.store(in: &self.cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func connect(to endpoint: NWEndpoint, displayName: String, pin: String) {
        generation &+= 1
        let gen = generation
        disconnect(silent: true)
        isConnected = false
        lastError = nil
        let peer = TeamPeer(id: UUID(), displayName: displayName, role: .guest)
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == gen, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.hostPeerID = peer.id
                    self.logger.info("[Guest] connected to \(String(describing: endpoint))")
                    self.startHeartbeat(generation: gen)
                    self.startPairingTimeout(generation: gen, pin: pin, peer: peer)
                case .failed(let err):
                    self.lastError = err.localizedDescription
                    self.isConnected = false
                    self.logger.error("[Guest] failed \(err.localizedDescription)")
                case .cancelled:
                    self.isConnected = false
                default: break
                }
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    func disconnect(silent: Bool = false) {
        generation &+= 1
        heartbeatTask?.cancel(); heartbeatTask = nil
        pairingTask?.cancel(); pairingTask = nil
        connection?.cancel(); connection = nil
        isConnected = false
        hostPeerID = nil
        if !silent { logger.info("[Guest] disconnected") }
    }

    func disconnect() { disconnect(silent: false) }

    private func startHeartbeat(generation: UInt64) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TeamConstants.heartbeatIntervalSeconds))
                guard let self, self.generation == generation, self.isConnected else { return }
                // heartbeat via Relay's guest framer (kept single path for now)
                self.logger.debug("[Guest] heartbeat")
            }
        }
    }

    private func startPairingTimeout(generation: UInt64, pin: String, peer: TeamPeer) {
        pairingTask?.cancel()
        pairingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TeamConstants.connectionTimeoutSeconds))
            guard let self, !Task.isCancelled, self.generation == generation, self.isConnected else { return }
            self.lastError = "配对超时"
            self.disconnect()
        }
    }
}
