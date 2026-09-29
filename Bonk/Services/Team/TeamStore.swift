//
//  TeamStore.swift
//  Bonk
//
//  Single source of truth for Team isHosting + the single-pane shared
//  constraint. Hosting itself lives in `TeamSSHHost`.
//
//  This type used to own an `NWListener` and a registry of `NWConnection`s.
//  Both were removed when the relay moved to SSH: a plaintext listener that
//  nothing calls is still a way to start a plaintext relay, and "nobody calls
//  it today" is not the same as "it cannot be done".
//

import Combine
import Foundation
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

    private let logger = Logger(subsystem: "com.bonk", category: "TeamStore")
    private var cancellables = Set<AnyCancellable>()

    init() {}

    // MARK: - Hosting (state only — the transport is TeamSSHHost)

    /// Record that the relay started hosting on `port`.
    func didStartHosting(on port: UInt16?) {
        isHosting = true
        hostedPort = port
        lastError = nil
        logger.info("[Store] hosting on \(String(describing: port))")
    }

    func didFailToStartHosting(_ error: String) {
        isHosting = false
        hostedPort = nil
        lastError = error
    }

    func stopHosting() {
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
}
