//
//  TerminalSelectionResponderTests.swift
//  BonkTests
//
//  `.requestTerminalSelection` -> active terminal -> `getSelection()` ->
//  `.terminalSelectionResponse`.
//
//  This path was broken in two independent ways, and both are exercised here:
//
//  1. The responder replied with the request's own object. Every sender posts
//     `object: nil`, so it always answered "" and never called `getSelection()`.
//  2. The responder lived on `TerminalContainerView`, which is the single-pane
//     terminal. A split tab renders `PaneTerminalView` instead, so there was no
//     responder at all and the request went unanswered until the caller's
//     timeout fired.
//
//  The tests post with `object: nil` — the way production does — and require the
//  real selection to come back.
//

import AppKit
import NIOConcurrencyHelpers
import SwiftTerm
import Testing
import XCTest
@testable import Bonk

@MainActor
final class TerminalSelectionResponderTests: XCTestCase {

    private var storedKeys: [TerminalViewCacheKey] = []
    private var responder: TerminalSelectionResponder?
    private var responseObserver: (any NSObjectProtocol)?

    override func tearDown() async throws {
        responder?.stop()
        responder = nil
        if let responseObserver { NotificationCenter.default.removeObserver(responseObserver) }
        responseObserver = nil
        for key in storedKeys { TerminalViewCache.shared.remove(key) }
        storedKeys = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeView(withText text: String) -> NativeTerminalView {
        let view = NativeTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        view.terminal.feed(byteArray: Array(text.utf8))
        view.selectAll()
        return view
    }

    private func makeCoordinator() -> ContainerTerminalCoordinator {
        ContainerTerminalCoordinator(
            onSend: { _ in },
            onResize: { _, _ in },
            onTitleChange: nil,
            copyOnSelect: false
        )
    }

    /// A manager with one active tab, plus that tab's active *pane* id — a
    /// different UUID from the tab's own id, which is the whole point.
    private func makeManagerWithActiveTab() throws -> (SessionManager, TerminalTab, UUID) {
        let manager = SessionManager()
        let host = HostItem(name: "probe", host: "10.0.0.1", port: 22, username: "u")
        let tab = TerminalTab(hostItem: host)
        manager.tabs.append(tab)
        manager.activeTabID = tab.id
        let paneID = try XCTUnwrap(tab.activePaneID)
        XCTAssertNotEqual(paneID, tab.id, "a pane id must differ from the tab id")
        return (manager, tab, paneID)
    }

    /// Install the responder and capture the next response synchronously.
    ///
    /// `NotificationCenter` delivers to a `.main` queue observer on the calling
    /// thread when already on main, so the post below is answered before it
    /// returns — no sleeping, and therefore no load-dependent flake.
    @discardableResult
    private func respondToRequest(manager: SessionManager) -> String?? {
        let box = NIOLockedValueBox<String??>(nil)
        responseObserver = NotificationCenter.default.addObserver(
            forName: .terminalSelectionResponse,
            object: nil,
            queue: .main
        ) { notification in
            // Read the object off the notification here; the `Notification`
            // itself is not Sendable, so it must not cross an isolation boundary.
            let text = notification.object as? String
            box.withLockedValue { $0 = .some(text) }
        }
        let responder = TerminalSelectionResponder(sessionManager: manager)
        responder.start()
        self.responder = responder

        // Exactly how production sends it: no object.
        NotificationCenter.default.post(name: .requestTerminalSelection, object: nil)
        return box.withLockedValue { $0 }
    }

    // MARK: - Tests

    /// A split tab must answer with the real selection.
    ///
    /// The view is cached under the tab's active *pane* id, which is how
    /// `PaneContainerBridge` keys it, and `activePaneID` is a different UUID
    /// from the tab's own id.
    func testSplitTabSelectionRequestReturnsRealSelection() throws {
        let (manager, tab, paneID) = try makeManagerWithActiveTab()
        let text = "selected from the left pane"
        let view = makeView(withText: text)
        TerminalViewCache.shared.store(
            TerminalViewCacheKey.pane(paneID, in: tab.id),
            view: view,
            coordinator: makeCoordinator()
        )
        storedKeys.append(TerminalViewCacheKey.pane(paneID, in: tab.id))

        let response = respondToRequest(manager: manager)
        XCTAssertEqual(response ?? nil, text,
                       "the responder must return the terminal's actual selection")
    }

    /// A single-pane tab must answer too — there the view is keyed by tab id.
    func testSinglePaneTabSelectionRequestReturnsRealSelection() throws {
        let (manager, tab, paneID) = try makeManagerWithActiveTab()
        let text = "single pane selection"
        let view = makeView(withText: text)
        TerminalViewCache.shared.store(
            TerminalViewCacheKey(tabID: tab.id, owner: .mainWindow),
            view: view,
            coordinator: makeCoordinator()
        )
        storedKeys.append(TerminalViewCacheKey(tabID: tab.id, owner: .mainWindow))

        let response = respondToRequest(manager: manager)
        XCTAssertEqual(response ?? nil, text)
    }

    /// The active pane is the one that answers, not merely any pane of the tab.
    func testActivePaneIsTheOneThatAnswers() throws {
        let (manager, tab, paneID) = try makeManagerWithActiveTab()
        let left = makeView(withText: "left pane text")
        let right = makeView(withText: "right pane text")
        TerminalViewCache.shared.store(
            TerminalViewCacheKey.pane(paneID, in: tab.id), view: right, coordinator: makeCoordinator()
        )
        storedKeys.append(TerminalViewCacheKey.pane(paneID, in: tab.id))
        // A sibling pane of the same tab, cached but not active.
        let siblingPane = UUID()
        TerminalViewCache.shared.store(
            TerminalViewCacheKey.pane(siblingPane, in: tab.id), view: left, coordinator: makeCoordinator()
        )
        storedKeys.append(TerminalViewCacheKey.pane(siblingPane, in: tab.id))

        let response = respondToRequest(manager: manager)
        XCTAssertEqual(response ?? nil, "right pane text",
                       "must answer from the active pane")
    }

    /// An empty selection is a real answer, and must arrive as "" rather than
    /// as no answer at all — the caller treats the two differently.
    func testEmptySelectionStillAnswers() throws {
        let (manager, tab, paneID) = try makeManagerWithActiveTab()
        let view = NativeTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        TerminalViewCache.shared.store(
            TerminalViewCacheKey(tabID: tab.id, owner: .mainWindow),
            view: view,
            coordinator: makeCoordinator()
        )
        storedKeys.append(TerminalViewCacheKey(tabID: tab.id, owner: .mainWindow))

        let response = respondToRequest(manager: manager)
        XCTAssertNotNil(response, "an empty selection is still a response")
        XCTAssertEqual(response ?? nil, "")
    }

    /// With no terminal to ask, the request is left unanswered so the caller's
    /// own timeout and fallback apply. A fabricated empty response would be
    /// indistinguishable from "the user selected nothing".
    func testNoActiveTabLeavesRequestUnanswered() throws {
        let manager = SessionManager()
        let response = respondToRequest(manager: manager)
        XCTAssertNil(response, "no active tab means no terminal to read a selection from")
    }
}
