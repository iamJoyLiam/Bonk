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
    /// The parent tab ID this view belongs to (used for eviction protection).
    /// For tab-level views, this equals tabID. For pane views, this is the parent tab's UUID.
    let parentTabID: UUID
    var outputStream: AsyncStream<String>?
    /// Backpressure callback — called after feeding text to signal bytes consumed.
    var onBytesProcessed: (@Sendable (Int) -> Void)?
    var constraints: [NSLayoutConstraint] = []

    init(tabID: UUID, parentTabID: UUID? = nil, view: SwiftTerm.TerminalView, coordinator: NSObject) {
        self.tabID = tabID
        self.parentTabID = parentTabID ?? tabID
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

    /// Diagnostic: track eviction events for debugging
    private var evictionLog: [(Date, String, UUID)] = []

    private init() {}

    #if os(macOS)
        private var activeTabIDProvider: (() -> UUID?)?
        private var memoryPressureSource: DispatchSourceMemoryPressure?

        /// Configure memory pressure handler with active tab provider.
        /// Must be called once after SessionManager is available.
        func configureMemoryPressure(activeTabIDProvider: @escaping () -> UUID?) {
            self.activeTabIDProvider = activeTabIDProvider
            installMemoryPressureHandler()
        }

        private func installMemoryPressureHandler() {
            // Remove any existing handler first
            if let existing = memoryPressureSource {
                existing.cancel()
                memoryPressureSource = nil
            }

            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let activeTabID = self.activeTabIDProvider?()
                let cacheCount = self.cache.count
                let eventMask = source.data
                Log.ui.info("[Cache] Memory pressure event: cache=\(cacheCount), active=\(activeTabID?.uuidString.prefix(8) ?? "nil"), event=\(eventMask.rawValue)")
                
                if eventMask.contains(.critical) {
                    // Critical memory pressure: evict non-active tabs to free memory
                    if cacheCount > 1 {
                        self.evictAllExceptActive(activeTabID: activeTabID)
                        Log.ui.info("[Cache] Critical pressure: evicted non-active tabs, remaining=\(self.cache.count)")
                    }
                } else {
                    // Warning level: only log, don't evict
                    // Users with 6-10 tabs should not lose terminal state on warning
                    Log.ui.info("[Cache] Warning level: keeping all \(cacheCount) cached tabs")
                }
            }
            source.resume()
            self.memoryPressureSource = source
        }
        
        /// Get diagnostic info about cache state
        func getDiagnosticInfo() -> String {
            let cacheInfo = cache.keys.map { $0.uuidString.prefix(8).description }.joined(separator: ", ")
            let accessInfo = accessOrder.map { $0.uuidString.prefix(8).description }.joined(separator: ", ")
            return "Cache: [\(cacheInfo)], AccessOrder: [\(accessInfo)]"
        }
        
        /// Log recent eviction events (for debugging)
        func logRecentEvictions() {
            let recent = evictionLog.suffix(10)
            for (date, reason, tabID) in recent {
                Log.ui.info("[Cache-Evict] \(date) - \(reason) - tab: \(tabID.uuidString.prefix(8))")
            }
        }
    #endif

    /// Store a terminal view for a tab.
    func store(tabID: UUID, parentTabID: UUID? = nil, view: SwiftTerm.TerminalView, coordinator: NSObject) {
        let cached = CachedTerminalView(tabID: tabID, parentTabID: parentTabID, view: view, coordinator: coordinator)
        cache[tabID] = cached
        updateAccessOrder(tabID)
        evictIfNeeded(except: parentTabID ?? tabID)
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
        guard let cached = cache[tabID] else {
            Log.ui.warning("[Cache] connectOutputStream: tab \(tabID.uuidString.prefix(8)) not in cache")
            return
        }
        cached.outputStream = stream
        cached.onBytesProcessed = onBytesProcessed
        if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
            Log.ui.info("[Cache] Connecting output stream for tab \(tabID.uuidString.prefix(8))")
            coordinator.startFeeding(from: stream, onBytesProcessed: onBytesProcessed)
        }
    }

    /// Evict all cached views except those belonging to the active tab (used on memory pressure).
    func evictAllExceptActive(activeTabID: UUID?) {
        guard let activeTabID else { return }
        
        // Protect all cache entries whose parentTabID matches the active tab
        let protectedIDs = Set(cache.values
            .filter { $0.parentTabID == activeTabID }
            .map { $0.tabID })
        
        let evictedIDs = cache.keys.filter { !protectedIDs.contains($0) }
        for id in evictedIDs {
            // Log the eviction
            evictionLog.append((Date(), "memory_pressure", id))
            if evictionLog.count > 100 { evictionLog.removeFirst(50) }
            
            // Cancel feed task before removing
            if let cached = cache[id] {
                if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
                    coordinator.feedTask?.cancel()
                    Log.ui.info("[Cache] Cancelled feedTask for tab \(id.uuidString.prefix(8))")
                }
                // Remove from superview if attached
                cached.view.removeFromSuperview()
            }
            cache.removeValue(forKey: id)
        }
        accessOrder = accessOrder.filter { protectedIDs.contains($0) }
    }

    /// Update scroll sensitivity for all cached terminal views.
    func updateScrollSensitivity(_ sensitivity: CGFloat) {
        for (_, cached) in cache {
            // Directly set SwiftTerm's scrollSensitivity property
            cached.view.scrollSensitivity = sensitivity
        }
    }

    // MARK: - LRU Private

    private func updateAccessOrder(_ tabID: UUID) {
        accessOrder.removeAll { $0 == tabID }
        accessOrder.append(tabID)
    }

    private func evictIfNeeded(except keepTabID: UUID) {
        // Protect all entries belonging to the same parent tab
        let protectedIDs = Set(cache.values
            .filter { $0.parentTabID == keepTabID }
            .map { $0.tabID })
        
        while cache.count > maxCachedTabs {
            if let evictID = accessOrder.first(where: { !protectedIDs.contains($0) }) {
                evictionLog.append((Date(), "lru_overflow", evictID))
                if evictionLog.count > 100 { evictionLog.removeFirst(50) }
                
                if let cached = cache[evictID] {
                    if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
                        coordinator.feedTask?.cancel()
                    }
                    cached.view.removeFromSuperview()
                }
                cache.removeValue(forKey: evictID)
                accessOrder.removeAll { $0 == evictID }
            } else {
                break
            }
        }
    }
}
