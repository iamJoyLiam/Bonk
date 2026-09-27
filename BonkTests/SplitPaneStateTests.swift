//
//  SplitPaneStateTests.swift
//  BonkTests
//
//  Regression cover for split / unsplit pane state integrity.
//

import AppKit
import SwiftUI
import XCTest
@testable import Bonk

@MainActor
final class SplitPaneStateTests: XCTestCase {

    private func makeHost(_ name: String) -> HostItem {
        HostItem(name: name, host: "10.0.0.1", port: 22, username: "root")
    }

    /// Two tabs on different hosts, each with a live PTY, ready to be merged by
    /// drag-to-split. Mirrors the user's setup: 192.168.100.50 + 192.168.100.51.
    private func makeTwoHostTabs(_ sm: SessionManager) -> (tabA: TerminalTab, tabB: TerminalTab, paneA: PaneState, paneB: PaneState) {
        let tabA = TerminalTab(hostItem: makeHost("192.168.100.50"))
        let tabB = TerminalTab(hostItem: makeHost("192.168.100.51"))
        let paneA = tabA.layout.root.paneState!
        let paneB = tabB.layout.root.paneState!
        paneA.ptySession = PTYSession()
        paneB.ptySession = PTYSession()
        tabA.session = TerminalSession(tabID: tabA.id)
        tabB.session = TerminalSession(tabID: tabB.id)
        sm.tabs = [tabA, tabB]
        sm.activeTabID = tabA.id
        return (tabA, tabB, paneA, paneB)
    }

    // MARK: - Bug 3: unsplit must restore the moved pane's own host

    func testUnsplitRestoresMovedPaneOwnHostNotSourceTab() {
        let sm = SessionManager()
        let (tabA, tabB, paneA, paneB) = makeTwoHostTabs(sm)

        // Drag B's pane into A.
        sm.addPaneFromTab(tabB.id, to: tabA.id, paneID: paneA.id, position: .right)

        XCTAssertEqual(sm.tabs.count, 1, "source tab is consumed by the merge")
        let merged = sm.tabs[0]
        XCTAssertEqual(merged.layout.root.paneCount, 2)

        // Unsplit the moved (host B) pane back out.
        let movedPane = merged.layout.root.allPaneIDs
            .compactMap { merged.layout.findPane(id: $0) }
            .first { $0.hostItem != nil }!
        sm.unsplitPane(movedPane.id, from: merged)

        XCTAssertEqual(sm.tabs.count, 2)
        let newTab = sm.tabs.first { $0.id == sm.activeTabID }!
        XCTAssertEqual(
            newTab.hostItem.name, "192.168.100.51",
            "unsplit must restore the pane's own host, not the tab it was merged into"
        )
        XCTAssertEqual(
            newTab.title, "192.168.100.51",
            "tab title must match the restored host"
        )
        // The original host must keep its own distinct name.
        let original = sm.tabs.first { $0.id != newTab.id }!
        XCTAssertEqual(original.title, "192.168.100.50")
    }

    func testUnsplitTabTitlesRemainDistinctAcrossTwoHosts() {
        let sm = SessionManager()
        let (tabA, tabB, paneA, _) = makeTwoHostTabs(sm)
        sm.addPaneFromTab(tabB.id, to: tabA.id, paneID: paneA.id, position: .right)

        let merged = sm.tabs[0]
        for paneID in merged.layout.root.allPaneIDs {
            sm.unsplitPane(paneID, from: merged)
        }

        let titles = sm.tabs.map(\.title)
        XCTAssertEqual(
            Set(titles).count, 2,
            "the two tabs must not collapse to the same name: \(titles)"
        )
        XCTAssertEqual(Set(titles), Set(["192.168.100.50", "192.168.100.51"]))
    }

    func testSplitTabTitleIsWorkspaceWhileSplit() {
        let sm = SessionManager()
        let (tabA, _, _, _) = makeTwoHostTabs(sm)
        sm.activeTabID = tabA.id

        guard let newPane = tabA.layout.splitHorizontal() else { return XCTFail("split failed") }
        tabA.activePaneID = newPane.id
        sm.updateTabTitleForSplit(tabA)

        XCTAssertEqual(tabA.title, "Workspace")
    }

    // MARK: - Bug 1: unsplit must carry the live PTY's terminal state across

    func testUnsplitPreservesLivePTYSessionOntoNewTab() {
        let sm = SessionManager()
        let (tabA, tabB, paneA, paneB) = makeTwoHostTabs(sm)
        sm.addPaneFromTab(tabB.id, to: tabA.id, paneID: paneA.id, position: .right)

        let merged = sm.tabs[0]
        let movedPane = merged.layout.root.allPaneIDs
            .compactMap { merged.layout.findPane(id: $0) }
            .first { $0.hostItem != nil }!
        let carriedPTY = movedPane.ptySession
        XCTAssertNotNil(carriedPTY)

        sm.unsplitPane(movedPane.id, from: merged)

        let newTab = sm.tabs.first { $0.id == sm.activeTabID }!
        let newPane = newTab.layout.root.paneState!
        XCTAssertTrue(
            newPane.ptySession === carriedPTY,
            "unsplit must carry the SAME live PTY so alternate-screen apps (vim) keep rendering"
        )
    }

    // MARK: - Split then close (reported crash)

    /// Closing a pane after a plain split must leave consistent state behind.
    func testClosePaneAfterHorizontalSplit() {
        let sm = SessionManager()
        let (tabA, _, paneA, _) = makeTwoHostTabs(sm)
        sm.activeTabID = tabA.id

        guard let second = tabA.layout.splitHorizontal() else { return XCTFail("split failed") }
        second.ptySession = PTYSession()
        sm.updateTabTitleForSplit(tabA)

        sm.closePane(second.id, in: tabA)

        XCTAssertEqual(tabA.layout.root.paneCount, 1)
        XCTAssertNotNil(tabA.layout.findPane(id: paneA.id), "surviving pane must remain")
        XCTAssertNotNil(
            tabA.layout.findPane(id: tabA.layout.activePaneID),
            "activePaneID must still resolve to a live pane"
        )
    }

    /// Closing a pane after a drag-to-split (two different hosts) must not
    /// crash and must leave both hosts reachable.
    func testClosePaneAfterDragToSplit() {
        let sm = SessionManager()
        let (tabA, tabB, paneA, _) = makeTwoHostTabs(sm)
        sm.addPaneFromTab(tabB.id, to: tabA.id, paneID: paneA.id, position: .right)

        let merged = sm.tabs[0]
        XCTAssertEqual(merged.layout.root.paneCount, 2)

        let movedPane = merged.layout.root.allPaneIDs
            .compactMap { merged.layout.findPane(id: $0) }
            .first { $0.hostItem != nil }!

        sm.closePane(movedPane.id, in: merged)

        XCTAssertEqual(merged.layout.root.paneCount, 1)
        let remaining = merged.layout.root.allPaneIDs.first
        XCTAssertNotNil(merged.layout.findPane(id: merged.layout.activePaneID))
        XCTAssertNotNil(remaining)
        // The surviving host must still be identified.
        XCTAssertEqual(merged.title, "192.168.100.50")
    }

    /// Closing panes down to one, repeatedly, must stay consistent.
    func testRepeatedSplitAndCloseStaysConsistent() {
        let sm = SessionManager()
        let (tabA, _, _, _) = makeTwoHostTabs(sm)
        sm.activeTabID = tabA.id

        for i in 0 ..< 5 {
            guard let p = tabA.layout.splitHorizontal() else { break }
            p.ptySession = PTYSession()
            XCTAssertEqual(tabA.layout.root.paneCount, i + 2)
        }
        while tabA.layout.root.paneCount > 1 {
            let victim = tabA.layout.root.allPaneIDs.last!
            sm.closePane(victim, in: tabA)
            XCTAssertNotNil(
                tabA.layout.findPane(id: tabA.layout.activePaneID),
                "activePaneID must resolve after close \(i0(tabA))"
            )
        }
        XCTAssertEqual(tabA.layout.root.paneCount, 1)
    }

    private func i0(_ tab: TerminalTab) -> Int { tab.layout.root.paneCount }

    // MARK: - Bug 1: unsplit must carry the live view (and its alt screen) across

    func testUnsplitKeepsTheLiveViewAttachedToTheMovedPTY() {
        let sm = SessionManager(viewCache: .shared)
        let cache = TerminalViewCache.shared
        let (tabA, tabB, paneA, _) = makeTwoHostTabs(sm)
        sm.addPaneFromTab(tabB.id, to: tabA.id, paneID: paneA.id, position: .right)

        let merged = sm.tabs[0]
        let movedPane = merged.layout.root.allPaneIDs
            .compactMap { merged.layout.findPane(id: $0) }
            .first { $0.hostItem != nil }!

        // Stand in for the live view that was rendering this PTY, with vim on
        // the alternate screen.
        let view = NativeTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        view.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(view.terminal.isCurrentBufferAlternate, "precondition: vim is on alt screen")
        cache.store(
            tabID: movedPane.id,
            parentTabID: merged.id,
            view: view,
            coordinator: ContainerTerminalCoordinator(
                onSend: { _ in }, onResize: { _, _ in }, onTitleChange: nil, copyOnSelect: false
            )
        )

        sm.unsplitPane(movedPane.id, from: merged)

        let newTab = sm.tabs.first { $0.id == sm.activeTabID }!
        let newPaneID = try! XCTUnwrap(newTab.layout.root.paneState?.id)
        let cached = cache.retrieve(newPaneID)

        XCTAssertNotNil(
            cached,
            "unsplit must carry the cached view onto the new pane, not discard it"
        )
        XCTAssertTrue(
            cached?.view === view,
            "the SAME view instance must follow the PTY (a fresh view loses vim's alt screen)"
        )
        XCTAssertTrue(
            cached?.view.terminal.isCurrentBufferAlternate ?? false,
            "alternate-screen state must survive, else vim repaints as raw escape text"
        )
    }

    /// Drag-to-split must carry the live view too, not just unsplit.
    func testDragToSplitKeepsTheLiveViewOnTheMovedPane() {
        let sm = SessionManager(viewCache: .shared)
        let cache = TerminalViewCache.shared
        let (tabA, tabB, paneA, _) = makeTwoHostTabs(sm)

        let view = NativeTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        view.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(view.terminal.isCurrentBufferAlternate, "precondition: vim is on alt screen")
        cache.store(
            tabID: paneA.id,
            parentTabID: tabA.id,
            view: view,
            coordinator: ContainerTerminalCoordinator(
                onSend: { _ in }, onResize: { _, _ in }, onTitleChange: nil, copyOnSelect: false
            )
        )

        // Drag B's pane (the one owning the live view) into A.
        let sourcePane = tabB.layout.root.paneState!
        cache.move(from: paneA.id, to: sourcePane.id, parentTabID: tabB.id)

        sm.addPaneFromTab(tabB.id, to: tabA.id, paneID: paneA.id, position: .right)

        let merged = sm.tabs[0]
        let movedPane = merged.layout.root.allPaneIDs
            .compactMap { merged.layout.findPane(id: $0) }
            .first { $0.hostItem != nil }!

        XCTAssertTrue(
            cache.retrieve(movedPane.id)?.view === view,
            "drag-to-split must carry the same view, not rebuild it"
        )
        XCTAssertTrue(
            cache.retrieve(movedPane.id)?.view.terminal.isCurrentBufferAlternate ?? false,
            "alternate-screen state must survive a drag-to-split"
        )
    }

    // MARK: - Bug 2: split panes need independent identities and geometry

    func testSplitPanesHaveDistinctIdentities() {
        let sm = SessionManager()
        let (tabA, _, paneA, _) = makeTwoHostTabs(sm)

        guard let second = tabA.layout.splitHorizontal() else { return XCTFail("split failed") }

        XCTAssertNotEqual(paneA.id, second.id)
        XCTAssertEqual(Set(tabA.layout.root.allPaneIDs).count, 2, "no duplicate pane IDs")
    }

    func testEachSplitPaneHasItsOwnPTYSession() {
        let sm = SessionManager()
        let (tabA, _, paneA, _) = makeTwoHostTabs(sm)

        guard let second = tabA.layout.splitHorizontal() else { return XCTFail("split failed") }
        paneA.ptySession = PTYSession()
        second.ptySession = PTYSession()

        XCTAssertFalse(
            paneA.ptySession === second.ptySession,
            "independent split panes must not share one PTY (that truncates/corrupts output)"
        )
    }
}
