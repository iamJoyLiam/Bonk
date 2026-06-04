//
//  TerminalViewCache.swift
//  Bonk
//
//  Caches terminal views to preserve state across tab switches.
//

import Foundation
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A cached terminal view with its coordinator.
@MainActor
final class CachedTerminalView {
    let view: SwiftTerm.TerminalView
    let coordinator: NSObject
    let tabID: UUID
    var outputStream: AsyncStream<String>?
    /// Backpressure callback — called after feeding text to signal bytes consumed.
    var onBytesProcessed: (@Sendable (Int) -> Void)?
    var constraints: [NSLayoutConstraint] = []

    init(tabID: UUID, view: SwiftTerm.TerminalView, coordinator: NSObject) {
        self.tabID = tabID
        self.view = view
        self.coordinator = coordinator
    }

}

/// Caches SwiftTerm TerminalView instances to preserve scroll position and state.
@MainActor
final class TerminalViewCache {
    static let shared = TerminalViewCache()

    /// Cached terminal views keyed by tab ID.
    private var cache: [UUID: CachedTerminalView] = [:]

    /// Store a terminal view for a tab.
    func store(tabID: UUID, view: SwiftTerm.TerminalView, coordinator: NSObject) {
        cache[tabID] = CachedTerminalView(tabID: tabID, view: view, coordinator: coordinator)
    }

    /// Retrieve a cached terminal view for a tab.
    func retrieve(_ tabID: UUID) -> CachedTerminalView? {
        return cache[tabID]
    }

    /// Remove a cached terminal view.
    func remove(_ tabID: UUID) {
        cache.removeValue(forKey: tabID)
    }

    /// Connect output stream to a cached view with backpressure callback.
    func connectOutputStream(
        _ stream: AsyncStream<String>,
        onBytesProcessed: @Sendable @escaping (Int) -> Void,
        to tabID: UUID
    ) {
        guard let cached = cache[tabID] else { return }
        cached.outputStream = stream
        cached.onBytesProcessed = onBytesProcessed
        if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
            coordinator.startFeeding(from: stream, onBytesProcessed: onBytesProcessed)
        }
    }
}
