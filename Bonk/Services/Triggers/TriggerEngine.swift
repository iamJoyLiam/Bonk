//
//  TriggerEngine.swift
//  Bonk
//
//  Pane-aware subscription engine for triggers (Phase 7).
//  Replaces per-chunk Task@MainActor in PTY yieldOutput.
//

import Foundation

@MainActor
final class TriggerEngine: ObservableObject {
    private var subscriptions: [UUID: Task<Void, Never>] = [:]

    func subscribe(paneID: UUID, rule: TriggerRule) {
        // Placeholder: line buffer -> match -> throttle -> notify
    }

    func unsubscribe(paneID: UUID) {
        subscriptions[paneID]?.cancel()
        subscriptions.removeValue(forKey: paneID)
    }
}
