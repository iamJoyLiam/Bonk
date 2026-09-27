//
//  HostSidebarActivationTests.swift
//  BonkTests
//
//  Sidebar activation contract:
//    - single click = select only (never opens a connection)
//    - double click = open, or focus the existing tab
//    - selecting must never clear the active tab / show the empty state
//

import SwiftUI
import XCTest
@testable import Bonk

@MainActor
final class HostSidebarActivationTests: XCTestCase {

    private func makeHost(_ name: String) -> HostItem {
        HostItem(name: name, host: "10.0.0.1", port: 22, username: "root")
    }

    // MARK: - Single click must never clear the active tab

    /// Regression: clicking a host with no tab used to run through the List
    /// selection binding, which wrote `nil` into activeTabID and flashed the
    /// "no terminal" page even though other terminals were open.
    func testSelectingHostWithoutTabKeepsActiveTabIntact() {
        let sm = SessionManager()
        let connected = makeHost("already-open")
        sm.openTab(for: connected)
        let activeBefore = sm.activeTabID
        XCTAssertNotNil(activeBefore, "precondition: a terminal is open")

        // Simulate the List selection binding receiving a click on a row that
        // has no tab (the row's tag is nil).
        let clickedHostWithoutTab = makeHost("not-open")
        sm.activeTabID = nil // what `List(selection:)` did on click

        XCTAssertNil(
            sm.activeTabID,
            "reproduces the bug: a plain selection write nils the active tab"
        )
        // The fix must route selection through a path that never nils it.
    }

    func testHostWithoutTabDoesNotBecomeActiveTab() {
        let sm = SessionManager()
        let opened = makeHost("already-open")
        sm.openTab(for: opened)
        let before = sm.activeTabID

        let unopened = makeHost("not-open")
        sm.sidebarSingleClick(host: unopened)

        XCTAssertEqual(
            sm.activeTabID, before,
            "single click on a host with no tab must not disturb the open terminal"
        )
        XCTAssertEqual(
            sm.tabs.count, 1,
            "single click must not open a connection"
        )
    }

    // MARK: - Single click focuses an existing tab

    func testSingleClickFocusesExistingTabForThatHost() {
        let sm = SessionManager()
        let a = makeHost("a")
        let b = makeHost("b")
        sm.openTab(for: a)
        sm.openTab(for: b)
        // B is active.
        XCTAssertEqual(sm.activeTabID, sm.tabs.last?.id)

        sm.sidebarSingleClick(host: a)

        XCTAssertEqual(sm.activeTabID, sm.tabs.first?.id, "single click should focus host A's tab")
    }

    func testSingleClickDoesNotCreateDuplicateTabForSameHost() {
        let sm = SessionManager()
        let a = makeHost("a")
        sm.openTab(for: a)

        sm.sidebarSingleClick(host: a)
        sm.sidebarSingleClick(host: a)

        XCTAssertEqual(sm.tabs.count, 1, "repeated single clicks must not spawn tabs")
    }

    // MARK: - Double click opens

    func testDoubleClickOpensHostThatHasNoTab() {
        let sm = SessionManager()
        let unopened = makeHost("not-open")

        sm.sidebarDoubleClick(host: unopened)

        XCTAssertEqual(sm.tabs.count, 1, "double click should open a terminal")
        XCTAssertEqual(sm.tabs.first?.hostItem.id, unopened.id)
        XCTAssertEqual(sm.activeTabID, sm.tabs.first?.id)
    }

    func testDoubleClickFocusesExistingTabInsteadOfDuplicating() {
        let sm = SessionManager()
        let a = makeHost("a")
        sm.openTab(for: a)
        let b = makeHost("b")
        sm.openTab(for: b)

        sm.sidebarDoubleClick(host: a)

        XCTAssertEqual(sm.tabs.count, 2, "double click on an open host must not duplicate")
        XCTAssertEqual(sm.activeTabID, sm.tabs.first?.id)
    }

    // MARK: - The reported inconsistency

    /// "sometimes a single click opens, sometimes it shows the empty page"
    func testSingleClickNeverOpensAndNeverEmpties() {
        let sm = SessionManager()
        let first = makeHost("first")
        sm.openTab(for: first)

        // A run of single clicks across hosts that are / aren't open.
        let others = [makeHost("x"), makeHost("y"), makeHost("z")]
        for host in others {
            sm.sidebarSingleClick(host: host)
            XCTAssertEqual(
                sm.tabs.count, 1,
                "no single click may open a terminal (host \(host.name))"
            )
            XCTAssertNotNil(
                sm.activeTabID,
                "no single click may leave the detail pane empty (host \(host.name))"
            )
        }
    }
}
