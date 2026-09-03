//
//  TeamStore.swift
//  Bonk
//
//  Single source of truth for Team isHosting + discovery (Phase 4).
//  One NWListener, one isHosting, HostSession(1 pane) constraint, injected SessionManager.
//

import Combine
import Foundation
import Network
import os

@MainActor
final class TeamStore: ObservableObject {
    static let shared = TeamStore()

    @Published var isHosting = false
    @Published var hostedPort: UInt16?
    @Published var lastError: String?

    // Single pane shared — architecture constraint: only 1 pane can be shared at a time.
    struct HostSession: Hashable, Sendable {
        let tabID: UUID
        let paneID: UUID
        var teamID: TeamSessionID { TeamSessionID(tabID: tabID, paneID: paneID) }
    }
    @Published var hostSession: HostSession?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let logger = Logger(subsystem: "com.bonk", category: "TeamStore")
    private var cancellables = Set<AnyCancellable>()

    init() {}

    // MARK: - Hosting (single NWListener)

    func startHosting(displayName: String, serviceType: String = TeamConstants.serviceType) throws {
        guard !isHosting else { return }
        let params = NWParameters.tcp
        let service = NWListener.Service(name: displayName, type: serviceType)
        let newListener = try NWListener(service: service, using: params)
        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let raw = newListener.port?.rawValue, raw != 0 { self.hostedPort = raw }
                case .failed(let err):
                    self.lastError = err.localizedDescription
                    self.hostedPort = nil
                case .cancelled:
                    self.hostedPort = nil
                default: break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self] _ in
            // Actual connection handling stays in TeamRelay/Host for now;
            // Store owns the listener lifecycle, Relay owns the session logic.
            // Single listener satisfies “one truth” — no second Bonjour listener.
            self?.logger.info("[Store] newConnection delegated to Relay")
        }
        newListener.start(queue: .global(qos: .utility))
        listener = newListener
        isHosting = true
        lastError = nil
        logger.info("[Store] hosting \(displayName) on \(String(describing: newListener.port))")
    }

    func stopHosting() {
        listener?.cancel()
        listener = nil
        for color in connections.values { color.cancel() }
        connections.removeAll()
        isHosting = false
        hostedPort = nil
        hostSession = nil
        logger.info("[Store] stopped hosting")
    }

    // MARK: - HostSession (1 pane)

    func setHostSession(tabID: UUID, paneID: UUID) {
        let next = HostSession(tabID: tabID, paneID: paneID)
        guard hostSession != next else { return }
        hostSession = next
        logger.info("[Store] hostSession → \(paneID.uuidString.prefix(8))")
    }

    func clearHostSession() {
        hostSession = nil
    }

    // MARK: - Connection registry (for Store-owned lifecycle)

    func register(connection: NWConnection) -> UUID {
        let id = UUID()
        connections[id] = connection
        return id
    }

    func unregister(id: UUID) {
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
    }

    var underlyingListener: NWListener? { listener }
}
