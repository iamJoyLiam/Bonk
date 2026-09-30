//
//  TerminalViewCacheOwnershipTests.swift
//  BonkTests
//
//  The terminal view cache is keyed by (tab, owning mount site), not by tab.
//
//  A tab can be mounted in two windows at once: the main window shows it, and
//  the Quake drop-down panel mounts a view for the same tab at the same time.
//  Keyed by tab alone they shared one slot, so the second mount evicted the
//  first from the index while both stayed alive, and the next update
//  reparented the wrong view across windows.
//
//  The tests use the real cache and real `NativeTerminalView`s. What they check
//  is ownership — that a second owner does not damage the first — not the shape
//  of the key, which could be satisfied by any two-field type.
//

import AppKit
import SwiftTerm
import Testing
import XCTest
@testable import Bonk

@MainActor
final class TerminalViewCacheOwnershipTests: XCTestCase {

    private var stored: [TerminalViewCacheKey] = []

    override func tearDown() async throws {
        for key in stored { TerminalViewCache.shared.remove(key) }
        stored = []
        try await super.tearDown()
    }

    private func makeView() -> NativeTerminalView {
        NativeTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
    }

    private func makeCoordinator() -> ContainerTerminalCoordinator {
        ContainerTerminalCoordinator(
            onSend: { _ in }, onResize: { _, _ in }, onTitleChange: nil, copyOnSelect: false
        )
    }

    @discardableResult
    private func store(_ key: TerminalViewCacheKey, view: NativeTerminalView) -> NativeTerminalView {
        TerminalViewCache.shared.store(key, view: view, coordinator: makeCoordinator())
        stored.append(key)
        return view
    }

    // MARK: - 1. Same tab, different owners

    /// Two windows mounting the same tab must not evict each other.
    ///
    /// This is the Quake case: the main window's view has to survive the panel
    /// mounting its own, or the main window's next update reuses the panel's
    /// view and AppKit moves it between windows.
    func testSecondOwnerDoesNotEvictTheFirst() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        let quakeKey = TerminalViewCacheKey(tabID: tabID, owner: .quakePanel)

        let mainView = store(mainKey, view: makeView())
        let quakeView = store(quakeKey, view: makeView())

        XCTAssertTrue(cache.retrieve(mainKey)?.view === mainView,
                      "the Quake mount must not evict the main window's view")
        XCTAssertTrue(cache.retrieve(quakeKey)?.view === quakeView)
        XCTAssertNotIdentical(cache.retrieve(mainKey)?.view, cache.retrieve(quakeKey)?.view,
                              "the two owners must hold distinct views")
    }

    /// Removing one owner must leave the other intact.
    func testRemovingOneOwnerLeavesTheOther() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        let quakeKey = TerminalViewCacheKey(tabID: tabID, owner: .quakePanel)

        let mainView = store(mainKey, view: makeView())
        store(quakeKey, view: makeView())

        cache.remove(quakeKey)

        XCTAssertNil(cache.retrieve(quakeKey))
        XCTAssertTrue(cache.retrieve(mainKey)?.view === mainView,
                      "closing the Quake panel must not take the main window's view with it")
    }

    /// Split panes of one tab are separate owners too.
    func testSplitPanesAreDistinctOwners() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let leftKey = TerminalViewCacheKey.pane(UUID(), in: tabID)
        let rightKey = TerminalViewCacheKey.pane(UUID(), in: tabID)

        let left = store(leftKey, view: makeView())
        let right = store(rightKey, view: makeView())

        XCTAssertTrue(cache.retrieve(leftKey)?.view === left)
        XCTAssertTrue(cache.retrieve(rightKey)?.view === right)
    }

    // MARK: - 2. Mount and update agree

    /// Mounting twice for the same owner must reuse the view, not create one.
    ///
    /// `makeNSView` used to call `createTerminalView` unconditionally while
    /// `updateNSView` consulted the cache. That asymmetry meant every mount was
    /// a miss, so opening the Quake panel always built a fresh terminal and
    /// replaced the entry the main window was using.
    func testRepeatedMountForOneOwnerReusesTheSameView() throws {
        let cache = TerminalViewCache.shared
        let key = TerminalViewCacheKey(tabID: UUID(), owner: .quakePanel)
        let first = store(key, view: makeView())

        // A second mount for the same owner: retrieve-then-reuse, as update does.
        let reused = cache.retrieve(key)
        XCTAssertTrue(reused?.view === first,
                      "a second mount for the same owner must reuse the cached view")
    }

    // MARK: - 3. closeTab removes what was stored

    /// Closing a tab must clear every entry it owns.
    ///
    /// `closeTab` looped `tab.paneIDs` and removed by pane id. A `PaneState`
    /// mints its own UUID, so for a single-pane tab `paneID != tab.id` and the
    /// main window's entry — stored under `(tab.id, .mainWindow)` — was never
    /// removed at all.
    func testRemovingATabClearsAllItsEntries() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        let quakeKey = TerminalViewCacheKey(tabID: tabID, owner: .quakePanel)
        let paneKey = TerminalViewCacheKey.pane(UUID(), in: tabID)
        // An unrelated tab that must survive.
        let otherTabID = UUID()
        let otherKey = TerminalViewCacheKey(tabID: otherTabID, owner: .mainWindow)

        store(mainKey, view: makeView())
        store(quakeKey, view: makeView())
        store(paneKey, view: makeView())
        store(otherKey, view: makeView())
        defer { cache.remove(otherKey) }

        cache.removeAll(forTab: tabID)

        XCTAssertNil(cache.retrieve(mainKey), "the main window entry must be removed on close")
        XCTAssertNil(cache.retrieve(quakeKey), "the Quake entry must be removed on close")
        XCTAssertNil(cache.retrieve(paneKey), "pane entries must be removed on close")
        XCTAssertNotNil(cache.retrieve(otherKey), "another tab's view must be untouched")
    }

    /// A single-pane tab stores under its own id, and must be removable by tab.
    func testSinglePaneEntryIsReachableByTabIDAlone() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        // The pane id a real single-pane tab would have: a *different* UUID.
        let paneID = UUID()
        XCTAssertNotEqual(paneID, tabID,
                          "a PaneState mints its own id, which is why the old pane-id removal missed")
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        store(mainKey, view: makeView())

        cache.removeAll(forTab: tabID)
        XCTAssertNil(cache.retrieve(mainKey),
                     "removing by pane id would have missed this entry entirely")
    }

    /// Closing a tab through `SessionManager` must clear its cached views.
    ///
    /// The tests above call `removeAll(forTab:)` directly, so they would stay
    /// green if `closeTab` stopped calling it. This drives the real close path,
    /// because the mismatch being fixed was between *what closeTab removed by*
    /// and *what the container stored under* — a wiring bug, not a cache bug.
    func testClosingATabClearsItsMainWindowEntry() async throws {
        let cache = TerminalViewCache.shared
        let manager = SessionManager()
        let host = HostItem(name: "owned", host: "10.0.0.1", port: 22, username: "u")
        let tab = TerminalTab(hostItem: host)
        manager.tabs.append(tab)
        manager.activeTabID = tab.id

        let mainKey = TerminalViewCacheKey(tabID: tab.id, owner: .mainWindow)
        let quakeKey = TerminalViewCacheKey(tabID: tab.id, owner: .quakePanel)
        store(mainKey, view: makeView())
        store(quakeKey, view: makeView())
        XCTAssertNotNil(cache.retrieve(mainKey), "precondition: main window view cached")

        // A real single-pane tab's pane id is a *different* UUID from the tab id,
        // which is exactly why removing by pane id used to miss this entry.
        XCTAssertNotEqual(tab.paneIDs.first, tab.id)

        await manager.closeTab(tab.id)

        XCTAssertNil(cache.retrieve(mainKey),
                     "closing a tab must clear the main window's cached view")
        XCTAssertNil(cache.retrieve(quakeKey),
                     "closing a tab must clear the Quake panel's cached view")
    }

    /// The entries a tab owns, across all owners.
    func testEntriesForTabSpansOwners() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        store(TerminalViewCacheKey(tabID: tabID, owner: .mainWindow), view: makeView())
        store(TerminalViewCacheKey(tabID: tabID, owner: .quakePanel), view: makeView())
        store(TerminalViewCacheKey.pane(UUID(), in: tabID), view: makeView())

        XCTAssertEqual(cache.entries(forTab: tabID).count, 3)
    }
}

// MARK: - Supplementary mount guard
//
// STRUCTURAL, NOT BEHAVIOURAL.
//
// Mutation B — restoring `makeNSView`'s unconditional create-and-store — is not
// headlessly testable: `MacTerminalContainerBridge` is `private`, so `@testable`
// cannot reach it, and `NSViewRepresentable.Context` has no public
// initialiser, so the method cannot be invoked even if it could. This is the
// same limitation as the SwiftUI drop registration guard.
//
// So the mount/reuse *behaviour* is covered by
// `testRepeatedMountForOneOwnerReusesTheSameView` on the cache, and what is
// asserted here is only that the mount path routes through that resolution
// rather than around it.
//
// Name-independent on purpose: an earlier guard elsewhere checked for an
// identifier and a mutation that restored the same defect under a different
// name passed straight through.

@MainActor
final class TerminalViewCacheMountGuardTests: XCTestCase {
    func testMountPathResolvesThroughTheCache() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Bonk/Views/Terminal/Container/TerminalContainerView.swift"
            ),
            encoding: .utf8
        )
        let mountStart = try XCTUnwrap(source.range(of: "func makeNSView("))
        let mountEnd = try XCTUnwrap(source.range(of: "func updateNSView(", range: mountStart.lowerBound..<source.endIndex))
        let mount = String(source[mountStart.lowerBound..<mountEnd.lowerBound])

        XCTAssertTrue(
            mount.contains("TerminalViewCache.shared.retrieve("),
            """
            makeNSView must consult the cache before creating. Creating             unconditionally is what made the Quake panel evict the main window's             live view from the index.
            """
        )
        XCTAssertFalse(
            source.contains("func setupTerminalView("),
            "the cache-bypassing setup path must not be reinstated alongside it"
        )
    }
}
