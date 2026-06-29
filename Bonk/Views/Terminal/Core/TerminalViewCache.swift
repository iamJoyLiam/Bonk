//
//  TerminalViewCache.swift
//  Bonk
//
//  Caches terminal views to preserve state across tab switches.
//

import Foundation
import os.log
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
/// Uses LRU eviction when cache exceeds maxCachedTabs.
@MainActor
final class TerminalViewCache {
    static let shared = TerminalViewCache()

    /// Cached terminal views keyed by tab ID.
    private var cache: [UUID: CachedTerminalView] = [:]

    /// LRU access order (most recently used at the end).
    private var accessOrder: [UUID] = []

    /// Maximum number of cached tabs before eviction.
    private let maxCachedTabs = 10

    private init() {
        // Memory pressure handling is done via evictIfNeeded during store operations
        #if os(macOS)
            setupMemoryPressureHandler()
        #endif
    }

    #if os(macOS)
        private var activeTabIDProvider: (() -> UUID?)?
        private var memoryPressureSource: DispatchSourceMemoryPressure?

        /// Configure memory pressure handler with active tab provider.
        func configureMemoryPressure(activeTabIDProvider: @escaping () -> UUID?) {
            self.activeTabIDProvider = activeTabIDProvider
            setupMemoryPressureHandler()
        }

        private func setupMemoryPressureHandler() {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let activeTabID = self.activeTabIDProvider?()
                self.evictAllExceptActive(activeTabID: activeTabID)
                os_log(.info, "[Cache] Memory pressure: evicted all except active tab")
            }
            source.resume()
            self.memoryPressureSource = source
        }
    #endif

    /// Store a terminal view for a tab.
    func store(tabID: UUID, view: SwiftTerm.TerminalView, coordinator: NSObject) {
        cache[tabID] = CachedTerminalView(tabID: tabID, view: view, coordinator: coordinator)
        updateAccessOrder(tabID)
        evictIfNeeded(except: tabID)
    }

    /// Retrieve a cached terminal view for a tab.
    func retrieve(_ tabID: UUID) -> CachedTerminalView? {
        if cache[tabID] != nil {
            updateAccessOrder(tabID)
        }
        return cache[tabID]
    }

    /// Remove a cached terminal view.
    func remove(_ tabID: UUID) {
        cache.removeValue(forKey: tabID)
        accessOrder.removeAll { $0 == tabID }
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

    /// Evict all cached views except the active tab (used on memory pressure).
    func evictAllExceptActive(activeTabID: UUID?) {
        for (id, _) in cache where id != activeTabID {
            cache.removeValue(forKey: id)
        }
        accessOrder = activeTabID.map { [$0] } ?? []
    }

    // MARK: - LRU Private

    private func updateAccessOrder(_ tabID: UUID) {
        accessOrder.removeAll { $0 == tabID }
        accessOrder.append(tabID)
    }

    private func evictIfNeeded(except keepTabID: UUID) {
        while cache.count > maxCachedTabs {
            if let evictID = accessOrder.first(where: { $0 != keepTabID }) {
                cache.removeValue(forKey: evictID)
                accessOrder.removeAll { $0 == evictID }
            } else {
                break
            }
        }
    }
}
