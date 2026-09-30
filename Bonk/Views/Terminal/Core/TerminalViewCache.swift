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

/// Which mounting site owns a cached terminal view.
///
/// A tab can be mounted in more than one place at once: the main window shows
/// it, and the Quake drop-down panel mounts a view for the same tab at the same
/// time. Keying the cache by tab ID alone gave those two windows one slot, so
/// the second mount evicted the first from the index while both stayed alive —
/// and the next update reparented the wrong view across windows.
///
/// The owner must be **stable** for the life of the mount site. A UUID minted
/// per `makeNSView` would not help: it would make every mount a cache miss and
/// guarantee the view is never reused.
enum TerminalViewOwner: Hashable, Sendable {
    /// The main window's single-pane container for a tab.
    case mainWindow
    /// A specific split pane in the main window.
    case pane(UUID)
    /// The Quake drop-down panel.
    case quakePanel
}

/// Identity of a cached terminal view: the tab, plus the site that owns it.
///
/// Store, retrieve and remove all take this, so the three lifecycle entry
/// points cannot disagree about what a view is keyed by. That disagreement was
/// real: the container stored under `tab.id` while `closeTab` removed under
/// `paneID`, and for a single-pane tab those are different UUIDs, so closing a
/// tab left its view cached forever.
struct TerminalViewCacheKey: Hashable, Sendable {
    let tabID: UUID
    let owner: TerminalViewOwner

    init(tabID: UUID, owner: TerminalViewOwner) {
        self.tabID = tabID
        self.owner = owner
    }

    /// A split pane of `tabID`.
    static func pane(_ paneID: UUID, in tabID: UUID) -> TerminalViewCacheKey {
        TerminalViewCacheKey(tabID: tabID, owner: .pane(paneID))
    }
}

/// A cached terminal view with its coordinator.
@MainActor
final class CachedTerminalView {
    let view: SwiftTerm.TerminalView
    let coordinator: NSObject
    /// The tab this view belongs to. For a split pane this is the *parent* tab,
    /// which is what eviction groups by — the pane's own id is in the owner.
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

    /// Cached terminal views, keyed by tab *and* owning mount site.
    private var cache: [TerminalViewCacheKey: CachedTerminalView] = [:]

    /// LRU access order (most recently used at the end).
    private var accessOrder: [TerminalViewCacheKey] = []

    /// Maximum number of cached **tabs** before eviction.
    ///
    /// Counted as distinct tab ids, not entries. A tab open in both the main
    /// window and the Quake panel owns two entries, and comparing against
    /// `cache.count` meant mounting the panel evicted a live tab — the
    /// second-oldest, not the oldest — losing its scrollback.
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
    #endif

    /// Store a terminal view under a (tab, owner) identity.
    func store(_ key: TerminalViewCacheKey, view: SwiftTerm.TerminalView, coordinator: NSObject) {
        let cached = CachedTerminalView(tabID: key.tabID, view: view, coordinator: coordinator)
        cache[key] = cached
        updateAccessOrder(key)
        evictIfNeeded(except: key.tabID)
    }

    /// Retrieve the view owned by a specific mount site.
    func retrieve(_ key: TerminalViewCacheKey) -> CachedTerminalView? {
        if cache[key] != nil {
            updateAccessOrder(key)
        }
        return cache[key]
    }

    /// Every entry belonging to a tab, across all owners.
    func entries(forTab tabID: UUID) -> [CachedTerminalView] {
        cache.filter { $0.key.tabID == tabID }.map(\.value)
    }

    // MARK: - Target resolution
    //
    // The cache holds one entry per *view*, and a view is keyed by pane ID when
    // the tab is split and by tab ID when it is not. Both layouts share this
    // dictionary, so "look this up by tab id" is only correct in one of them.
    //
    // These two functions are the single definition of which view a command
    // should act on. Callers go through one of them rather than picking a key.

    /// The view a **tab-level** command (Copy, Select All, focus) should act on:
    /// the tab's active pane.
    ///
    /// Falls back to the tab's own entry (single-pane layout) and then to any
    /// view belonging to that tab, so a stale `activePaneID` degrades to doing
    /// something sensible rather than silently doing nothing.
    func retrieveActivePane(tabID: UUID, activePaneID: UUID?) -> CachedTerminalView? {
        if let activePaneID {
            let paneKey = TerminalViewCacheKey.pane(activePaneID, in: tabID)
            if let cached = cache[paneKey] {
                updateAccessOrder(paneKey)
                return cached
            }
        }
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        if let cached = cache[mainKey] {
            updateAccessOrder(mainKey)
            return cached
        }
        // Any view of this tab, most recently used first — the same order the
        // cache already evicts by, so the fallback is deterministic instead of
        // whatever order the dictionary happens to yield. Never another tab's
        // view.
        let key = accessOrder.last { cache[$0]?.tabID == tabID }
        guard let key, let cached = cache[key] else { return nil }
        updateAccessOrder(key)
        return cached
    }

    /// The view a **pane context menu** should act on: the pane the user
    /// right-clicked.
    ///
    /// The menu already knows the exact pane, so this does not guess. It still
    /// checks the tab's own entry because in a single-pane tab that is the same
    /// view under a different key.
    func retrieveForPane(paneID: UUID, tabID: UUID) -> CachedTerminalView? {
        let paneKey = TerminalViewCacheKey.pane(paneID, in: tabID)
        if let cached = cache[paneKey] {
            updateAccessOrder(paneKey)
            return cached
        }
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        if let cached = cache[mainKey] {
            updateAccessOrder(mainKey)
            return cached
        }
        return nil
    }

    /// Find a pane's view when only the pane id is known.
    ///
    /// A *query*, not a lifecycle key: a `PaneState` UUID is unique across the
    /// app, so this is well defined without the owning tab. Lifecycle operations
    /// (store / retrieve / remove) still require the full key, so they cannot
    /// silently act on the wrong owner.
    func findPaneView(paneID: UUID) -> CachedTerminalView? {
        guard let key = accessOrder.last(where: {
            if case let .pane(id) = $0.owner { return id == paneID }
            return false
        }), let cached = cache[key] else { return nil }
        updateAccessOrder(key)
        return cached
    }

    /// Remove a cached terminal view.
    ///
    /// The view is NOT detached from its superview here. `remove()` is reached
    /// from SwiftUI state mutations (closing a pane), so touching the AppKit
    /// hierarchy synchronously pulls the view out from under SwiftUI while it
    /// still owns the container — AppKit then hits
    /// "not legal to call -layoutSubtreeIfNeeded on a view which is already
    /// being laid out" and the app dies. SwiftUI removes the view itself once
    /// the pane leaves the layout.
    func remove(_ key: TerminalViewCacheKey) {
        let cached = cache.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
        guard let cached else { return }
        if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
            coordinator.feedTask?.cancel()
            coordinator.feedTask = nil
            if let engine = coordinator.terminalEngine {
                if let id = coordinator.engineConsumerID { engine.unsubscribe(id) }
                if let id = coordinator.teamConsumerID { engine.unsubscribe(id) }
            }
            coordinator.engineConsumerID = nil
            coordinator.engineConsumer = nil
            coordinator.teamConsumerID = nil
            coordinator.teamConsumer = nil
            coordinator.terminalEngine = nil
            coordinator.removeInlineCompletionMonitor()
        }
        cached.outputStream = nil
        cached.onBytesProcessed = nil
    }

    /// Remove every entry a tab owns, across all mount sites.
    ///
    /// Closing a tab previously looped its `paneIDs` and removed each by pane id.
    /// That is the wrong key for a single-pane tab: the main window's container
    /// stores under `(tab.id, .mainWindow)`, and a `PaneState` mints its own
    /// UUID, so `paneID != tab.id` and the main window's view was never removed
    /// at all. Removing by tab cannot disagree with how the entry was stored.
    func removeAll(forTab tabID: UUID) {
        for key in accessOrder.reversed() where cache[key]?.tabID == tabID {
            remove(key)
        }
        // Anything not yet in the access order (defensive; store always adds).
        for key in cache.keys where key.tabID == tabID {
            remove(key)
        }
    }

    /// Connect output stream to a cached view with backpressure callback.
    func connectOutputStream(
        _ stream: AsyncStream<String>,
        onBytesProcessed: @Sendable @escaping (Int) -> Void,
        to key: TerminalViewCacheKey
    ) {
        guard let cached = cache[key] else {
            Log.ui.warning("[Cache] connectOutputStream: owner of tab \(key.tabID.uuidString.prefix(8)) not in cache")
            return
        }
        cached.outputStream = stream
        cached.onBytesProcessed = onBytesProcessed
        if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
            Log.ui.info("[Cache] Connecting output stream for tab \(key.tabID.uuidString.prefix(8))")
            coordinator.startFeeding(from: stream, onBytesProcessed: onBytesProcessed)
        }
    }

    /// Replace the cached output stream with a fresh stream from a new PTY
    /// session (after reconnect) and reset the terminal so the new session
    /// starts clean. Without this the view keeps feeding from the closed old
    /// session and never renders the new one.
    /// Rebind every entry a tab owns, across all owners.
    ///
    /// A reconnect must reach the main window *and* the Quake panel: both mount
    /// a view for the tab, and rebinding only one leaves the other feeding from
    /// the closed session.
    func rebindOutputStream(forTab tabID: UUID, to session: PTYSession) {
        for key in accessOrder.reversed() where cache[key]?.tabID == tabID {
            rebindOutputStream(for: key, to: session)
        }
    }

    /// Rebind one owner. Public for tests; prefer `rebindOutputStream(forTab:to:)`.
    func rebindOutputStream(for key: TerminalViewCacheKey, to session: PTYSession) {
        guard let cached = cache[key] else { return }

        if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
            coordinator.feedTask?.cancel()
            coordinator.feedTask = nil
        }
        cached.outputStream = nil
        cached.onBytesProcessed = nil

        let result = session.makeOutputStream()
        connectOutputStream(result.stream, onBytesProcessed: result.onBytesProcessed, to: key)

        // Full reset — the old scrollback belongs to the dead session.
        cached.view.terminal.resetToInitialState()
        // The new PTY starts at its own default size while the view is already
        // laid out, and the view's cached geometry would otherwise suppress the
        // resize — leaving the fresh session at the wrong column count.
        (cached.view as? NativeTerminalView)?.invalidateSyncedSize()
    }

    /// Re-key a cached view from one pane to another WITHOUT tearing it down.
    ///
    /// Used when a live PTY moves between panes/tabs (unsplit, drag-to-split).
    /// The view holds the terminal's scrollback AND its alternate-screen state
    /// (vim/less), so destroying and recreating it makes a running full-screen
    /// app repaint as raw escape text. The feed task, stream and engine
    /// subscription all stay attached to the same PTY, so the view must move
    /// with it.
    @discardableResult
    func move(from oldKey: TerminalViewCacheKey, to newKey: TerminalViewCacheKey) -> CachedTerminalView? {
        guard oldKey != newKey, let cached = cache.removeValue(forKey: oldKey) else { return nil }
        accessOrder.removeAll { $0 == oldKey }

        // Re-key the entry and re-parent it; the view/coordinator/stream and the
        // running feed task are intentionally left untouched.
        let moved = CachedTerminalView(
            tabID: newKey.tabID,
            view: cached.view,
            coordinator: cached.coordinator
        )
        moved.outputStream = cached.outputStream
        moved.onBytesProcessed = cached.onBytesProcessed
        moved.constraints = cached.constraints
        cache[newKey] = moved
        updateAccessOrder(newKey)
        evictIfNeeded(except: newKey.tabID)
        return moved
    }

    /// Detach a view from its superview without doing it inside a layout pass.
    /// Eviction can be triggered from memory pressure, which can land while
    /// AppKit is mid-layout; removing the view there trips AppKit's layout
    /// recursion guard.
    private func detachFromSuperview(_ view: SwiftTerm.TerminalView) {
        guard view.superview != nil else { return }
        DispatchQueue.main.async { [weak view] in
            view?.removeFromSuperview()
        }
    }

    /// Evict all cached views except those belonging to the active tab (used on memory pressure).
    func evictAllExceptActive(activeTabID: UUID?) {
        guard let activeTabID else { return }

        // Protect all cache entries belonging to the active tab, across owners
        let protectedIDs = Set(cache.keys.filter { $0.tabID == activeTabID })

        let evictedKeys = cache.keys.filter { !protectedIDs.contains($0) }
        for key in evictedKeys {
            evictionLog.append((Date(), "memory_pressure", key.tabID))
            if evictionLog.count > 100 { evictionLog.removeFirst(50) }

            if let cached = cache[key] {
                if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
                    coordinator.feedTask?.cancel()
                    Log.ui.info("[Cache] Cancelled feedTask for tab \(key.tabID.uuidString.prefix(8))")
                }
                detachFromSuperview(cached.view)
            }
            cache.removeValue(forKey: key)
        }
        accessOrder = accessOrder.filter { protectedIDs.contains($0) }
    }

    /// Whether any of the given panes is currently in alternate screen (vim/less).
    func isAnyPaneAlternate(paneIDs: [UUID], in tabID: UUID) -> Bool {
        for paneID in paneIDs {
            let key = TerminalViewCacheKey.pane(paneID, in: tabID)
            if let cached = cache[key], cached.view.terminal.isCurrentBufferAlternate { return true }
        }
        return false
    }

    /// Update scroll sensitivity for all cached terminal views.
    func updateScrollSensitivity(_ sensitivity: CGFloat) {
        for (_, cached) in cache {
            // Directly set SwiftTerm's scrollSensitivity property
            cached.view.scrollSensitivity = sensitivity
        }
    }

    // MARK: - LRU Private

    private func updateAccessOrder(_ key: TerminalViewCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded(except keepTabID: UUID) {
        // Protect all entries belonging to the same parent tab
        let protectedIDs = Set(cache.keys.filter { $0.tabID == keepTabID })

        // The budget is in tabs, so a second owner of an already-cached tab is
        // free and never costs another tab its entry.
        while Set(cache.keys.map(\.tabID)).count > maxCachedTabs {
            if let evictKey = accessOrder.first(where: { !protectedIDs.contains($0) }) {
                evictionLog.append((Date(), "lru_overflow", evictKey.tabID))
                if evictionLog.count > 100 { evictionLog.removeFirst(50) }

                if let cached = cache[evictKey] {
                    if let coordinator = cached.coordinator as? ContainerTerminalCoordinator {
                        coordinator.feedTask?.cancel()
                    }
                    detachFromSuperview(cached.view)
                }
                cache.removeValue(forKey: evictKey)
                accessOrder.removeAll { $0 == evictKey }
            } else {
                break
            }
        }
    }
}
