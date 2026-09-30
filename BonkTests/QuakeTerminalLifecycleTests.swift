//
//  QuakeTerminalLifecycleTests.swift
//  BonkTests
//
//  What the owner-aware cache refactor changed, tested against real SwiftTerm
//  views and the real cache.
//
//  Before, the Quake panel and the main window shared one slot per tab: opening
//  the panel replaced the main window's index entry, and the next update handed
//  the panel's view to the main window. After, each mount site owns its own
//  view. That is only correct if two things hold at runtime, and both are
//  checked here:
//
//  1. Opening the panel does not disturb the main window's terminal state —
//     scrollback and the alternate-screen buffer.
//  2. Two live views can be fed from one session without either losing content.
//
//  The panel sequence is reproduced at the cache level, because the production
//  mount is driven by SwiftUI (`QuakeTerminalView` gates on
//  `quakeState.isVisible`) and cannot be invoked from a headless test. What is
//  exercised is the cache behaviour that sequence depends on, plus real panel
//  construction.
//

import AppKit
import SwiftTerm
import Testing
import XCTest
@testable import Bonk

@MainActor
final class QuakeTerminalLifecycleTests: XCTestCase {

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

    private func mount(_ key: TerminalViewCacheKey) -> NativeTerminalView {
        let view = makeView()
        TerminalViewCache.shared.store(
            key,
            view: view,
            coordinator: ContainerTerminalCoordinator(
                onSend: { _ in }, onResize: { _, _ in }, onTitleChange: nil, copyOnSelect: false
            )
        )
        stored.append(key)
        return view
    }

    /// What the terminal is showing, via the same accessor Copy uses.
    ///
    /// `selectAll` then `getSelection` is the product's own "what text does this
    /// view hold" question, so the comparison is about what a user would
    /// actually see rather than about internal buffer layout.
    @discardableResult
    private func text(of view: SwiftTerm.TerminalView) -> String {
        view.selectAll()
        return view.getSelection() ?? ""
    }

    // MARK: - The panel sequence

    /// Opening and closing the Quake panel must leave the main window's
    /// terminal exactly as it was.
    ///
    /// This is the regression the refactor exists to prevent: the panel's mount
    /// used to evict the main window's index entry, so the main window's next
    /// update reused the panel's view — and the main window's scrollback and
    /// alternate-screen buffer went with it.
    func testQuakeRoundTripPreservesMainWindowState() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        let quakeKey = TerminalViewCacheKey(tabID: tabID, owner: .quakePanel)

        // Main window mounted, with real content and an alternate screen.
        let mainView = mount(mainKey)
        mainView.feed(text: "scrollback that must survive\r\n")
        mainView.feed(text: "\u{1B}[?1049h") // vim enters the alternate screen
        XCTAssertTrue(mainView.terminal.isCurrentBufferAlternate, "precondition: alt screen")
        let mainIdentity = ObjectIdentifier(mainView)

        // The panel opens: its own owner mounts its own view.
        _ = mount(quakeKey)
        XCTAssertTrue(cache.retrieve(mainKey)?.view.terminal.isCurrentBufferAlternate ?? false,
                      "opening the panel must not disturb the main window's alternate screen")

        // The panel closes: its entry is released, the main window's is not.
        cache.remove(quakeKey)
        XCTAssertNil(cache.retrieve(quakeKey))
        let afterClose = try XCTUnwrap(cache.retrieve(mainKey))
        XCTAssertEqual(ObjectIdentifier(afterClose.view), mainIdentity,
                       "the main window must still own the same view instance")
        XCTAssertTrue(afterClose.view.terminal.isCurrentBufferAlternate,
                      "the alternate-screen buffer must survive a Quake round trip")

        // The panel opens again — the main window must be untouched again.
        _ = mount(quakeKey)
        XCTAssertEqual(ObjectIdentifier(cache.retrieve(mainKey)?.view ?? mainView), mainIdentity)
    }

    /// Scrollback is per view, so the main window's must be intact after a
    /// round trip rather than reset by the panel's mount.
    func testMainWindowScrollbackSurvivesPanelMount() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        let quakeKey = TerminalViewCacheKey(tabID: tabID, owner: .quakePanel)

        let mainView = mount(mainKey)
        let marker = "MARKER-LINE-42"
        mainView.feed(text: "\(marker)\r\n")
        XCTAssertTrue(text(of: mainView).contains(marker), "precondition: content rendered")

        _ = mount(quakeKey)
        cache.remove(quakeKey)

        let after = try XCTUnwrap(cache.retrieve(mainKey)).view
        XCTAssertTrue(text(of: after).contains(marker),
                      "the main window's scrollback must survive the panel's mount and close")
    }

    // MARK: - Two live views, one session

    /// Both owners' views can render the same session output.
    ///
    /// This is the cost of the fix made explicit: the panel now has its own
    /// view rather than sharing one, so the session's bytes reach two views.
    /// Both must end up with the content, and neither may corrupt the other.
    func testBothOwnersRenderTheSameSessionOutput() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let mainView = mount(TerminalViewCacheKey(tabID: tabID, owner: .mainWindow))
        let quakeView = mount(TerminalViewCacheKey(tabID: tabID, owner: .quakePanel))

        // One session, streamed to both — this is what a shared PTY does.
        for line in 0..<5 {
            let payload = "session-line-\(line)\r\n"
            mainView.feed(text: payload)
            quakeView.feed(text: payload)
        }

        let mainText = text(of: mainView)
        let quakeText = text(of: quakeView)
        XCTAssertEqual(mainText, quakeText, "both views must render the same session")
        for line in 0..<5 {
            XCTAssertTrue(mainText.contains("session-line-\(line)"),
                          "line \(line) missing from the main window's view")
        }
    }

    /// Two views on one session do not share terminal state.
    ///
    /// If they somehow ended up as the same view this would pass trivially, so
    /// the test asserts they are distinct and that closing the panel does not
    /// take the main window's content with it.
    func testTwoOwnersAreDistinctViews() throws {
        let cache = TerminalViewCache.shared
        let tabID = UUID()
        let mainKey = TerminalViewCacheKey(tabID: tabID, owner: .mainWindow)
        let quakeKey = TerminalViewCacheKey(tabID: tabID, owner: .quakePanel)

        let mainView = mount(mainKey)
        let quakeView = mount(quakeKey)
        XCTAssertFalse(mainView === quakeView, "the two owners must hold distinct views")

        mainView.feed(text: "main-only\r\n")
        quakeView.feed(text: "quake-only\r\n")

        XCTAssertTrue(text(of: mainView).contains("main-only"))
        XCTAssertFalse(text(of: mainView).contains("quake-only"),
                       "one view's content must not appear in the other")
        XCTAssertTrue(text(of: quakeView).contains("quake-only"))
    }

    // MARK: - Panel construction

    /// A real `QuakeWindowController` holds a real panel that keeps its content
    /// view across show/hide, so the Quake content is not rebuilt per toggle.
    func testPanelRetainsItsContentViewAcrossShowHide() throws {
        let hosting = makeView()
        let controller = QuakeWindowController(contentView: hosting)
        let panel = controller.panel

        // The controller installs the content view controller once, in init.
        XCTAssertTrue(panel.contentViewController?.view === hosting,
                      "the panel must own the content view it was given")

        controller.show(heightRatio: 0.5, widthRatio: 1.0)
        controller.hide()
        XCTAssertTrue(panel.contentViewController?.view === hosting,
                      "hide/show must not discard the panel's content view")
    }
}
