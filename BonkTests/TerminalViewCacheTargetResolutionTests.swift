//
//  TerminalViewCacheTargetResolutionTests.swift
//  BonkTests
//
//  `TerminalViewCache` is keyed two different ways in production:
//
//    TerminalContainerView   →  store(tabID: tabID)                    single pane
//    PaneContainerBridge     →  store(tabID: paneID, parentTabID: tab) split
//
//  Both go into the same dictionary, and the key field is named `tabID` even
//  when it holds a pane ID. `copySelection` looked a tab up with
//  `retrieve(activeTab.id)`, which is a hit for a single-pane tab and a miss
//  the moment the tab is split — so Copy silently did nothing, with no error
//  and no "Copied" feedback to tell the user it had failed.
//
//  These tests use the real cache, real views and real coordinators. The
//  question is what the production lookup resolves to, not what a mock says.
//

import AppKit
import SwiftTerm
import Testing
import XCTest
@testable import Bonk

@MainActor
final class TerminalViewCacheTargetResolutionTests: XCTestCase {

    private var storedKeys: [UUID] = []

    override func tearDown() async throws {
        for key in storedKeys { TerminalViewCache.shared.remove(key) }
        storedKeys = []
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
            onSend: { _ in },
            onResize: { _, _ in },
            onTitleChange: nil,
            copyOnSelect: false
        )
    }

    /// Store a view the way the split-pane bridge does: keyed by pane ID, with
    /// the owning tab recorded separately.
    @discardableResult
    private func storePane(
        _ tabID: UUID,
        _ paneID: UUID,
        view: NativeTerminalView
    ) -> NativeTerminalView {
        TerminalViewCache.shared.store(
            tabID: paneID,
            parentTabID: tabID,
            view: view,
            coordinator: makeCoordinator()
        )
        storedKeys.append(paneID)
        return view
    }

    /// Store a view the way the single-pane container does: keyed by tab ID.
    @discardableResult
    private func storeSinglePaneTab(
        _ tabID: UUID,
        view: NativeTerminalView
    ) -> NativeTerminalView {
        TerminalViewCache.shared.store(
            tabID: tabID,
            view: view,
            coordinator: makeCoordinator()
        )
        storedKeys.append(tabID)
        return view
    }

    // MARK: - The defect

    /// Copy on a split tab must reach the active pane.
    ///
    /// Against the old `retrieve(activeTab.id)` lookup this is the failure: the
    /// tab has no entry under its own id once split, so the guard returned
    /// early and nothing was copied.
    ///
    /// The *other* pane is touched last on purpose. It is then the most recently
    /// used entry, so a resolution that ignored `activePaneID` and fell back to
    /// recency would hand back the wrong view — which is what makes this test
    /// able to distinguish "used the active pane" from "returned some pane".
    func testActivePaneOfSplitTabIsReachable() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let leftPane = UUID()
        let rightPane = UUID()
        let left = storePane(tabID, leftPane, view: makeView())
        let right = storePane(tabID, rightPane, view: makeView())
        // Make the non-active pane the most recently used.
        _ = cache.retrieve(leftPane)

        // The lookup the old code performed: the tab's own id. This is the bug.
        XCTAssertNil(cache.retrieve(tabID),
                     "a split tab has no entry under its own id — the old lookup missed")

        let resolved = cache.retrieveActivePane(tabID: tabID, activePaneID: rightPane)
        XCTAssertNotNil(resolved, "the active pane of a split tab must be reachable")
        XCTAssertTrue(resolved?.view === right,
                      "must resolve to the ACTIVE pane, not merely the most recent one")
        XCTAssertTrue(resolved?.view !== left)
    }

    /// A single-pane tab is still reachable. The fix must not trade one broken
    /// layout for the other.
    func testSinglePaneTabIsReachable() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let view = storeSinglePaneTab(tabID, view: makeView())

        // The active pane id and the tab id are the same object here.
        let resolved = cache.retrieveActivePane(tabID: tabID, activePaneID: tabID)
        XCTAssertTrue(resolved?.view === view, "a single-pane tab must resolve")

        // Even when the caller has no active pane id at all.
        let fallback = cache.retrieveActivePane(tabID: tabID, activePaneID: nil)
        XCTAssertTrue(fallback?.view === view,
                      "a tab-level command with no known active pane must still work")
    }

    /// Degrade, don't fail silently: if the active pane is not cached, fall
    /// back to another view of the same tab rather than doing nothing.
    func testFallsBackToAnyViewOfTheTab() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let left = storePane(tabID, UUID(), view: makeView())

        let resolved = cache.retrieveActivePane(
            tabID: tabID,
            activePaneID: UUID() // never cached
        )
        XCTAssertNotNil(resolved, "should degrade to a view of this tab, not fail")
        XCTAssertTrue(resolved?.view === left)
    }

    /// A tab with nothing cached resolves to nil, rather than to some other
    /// tab's view.
    func testUnknownTabResolvesToNil() throws {
        let cache = TerminalViewCache.shared
        let other = storePane(UUID(), UUID(), view: makeView())
        _ = other

        XCTAssertNil(cache.retrieveActivePane(tabID: UUID(), activePaneID: nil),
                     "must not fall back to an unrelated tab's view")
    }

    // MARK: - Context menu target

    /// The context menu knows exactly which pane was right-clicked, so it must
    /// act on that pane — in both layouts.
    func testContextMenuTargetsTheRightClickedPane() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let leftPane = UUID()
        let rightPane = UUID()
        let left = storePane(tabID, leftPane, view: makeView())
        storePane(tabID, rightPane, view: makeView())

        XCTAssertTrue(cache.retrieveForPane(paneID: leftPane, tabID: tabID)?.view === left,
                      "right-clicking the left pane must act on the left pane")
    }

    /// In a single-pane tab the pane id and the tab id are the same view, so
    /// the menu must still find it.
    func testContextMenuResolvesSinglePaneTab() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let view = storeSinglePaneTab(tabID, view: makeView())

        XCTAssertTrue(cache.retrieveForPane(paneID: tabID, tabID: tabID)?.view === view,
                      "a single-pane tab's context menu must resolve")
    }
}
