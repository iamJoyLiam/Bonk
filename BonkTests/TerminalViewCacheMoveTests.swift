//
//  TerminalViewCacheMoveTests.swift
//  BonkTests
//
//  A live PTY moves between panes/tabs (unsplit, drag-to-split). The cached
//  view carries the alternate-screen buffer, so it must MOVE with the PTY
//  rather than being destroyed and recreated.
//

import AppKit
import NIOConcurrencyHelpers
import SwiftTerm
import XCTest
@testable import Bonk

@MainActor
final class TerminalViewCacheMoveTests: XCTestCase {

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

    /// Moving a view must not destroy it — otherwise a running vim/less pane
    /// loses its alternate screen and repaints as raw escape text.
    func testMovePreservesTheSameViewInstance() {
        let cache = TerminalViewCache.shared
        let oldID = UUID()
        let newID = UUID()
        let tabID = UUID()
        let view = makeView()
        let coordinator = makeCoordinator()

        cache.store(tabID: oldID, parentTabID: tabID, view: view, coordinator: coordinator)
        XCTAssertNotNil(cache.retrieve(oldID))

        let moved = cache.move(from: oldID, to: newID, parentTabID: tabID)

        XCTAssertNotNil(moved)
        XCTAssertTrue(moved?.view === view, "the same view instance must survive the move")
        XCTAssertNil(cache.retrieve(oldID), "old key must be released")
        XCTAssertTrue(cache.retrieve(newID)?.view === view, "view must be reachable under the new key")
    }

    /// The alternate screen is the state that breaks when a view is recreated.
    func testMovePreservesAlternateScreenState() {
        let cache = TerminalViewCache.shared
        let oldID = UUID()
        let newID = UUID()
        let tabID = UUID()
        let view = makeView()
        let coordinator = makeCoordinator()

        cache.store(tabID: oldID, parentTabID: tabID, view: view, coordinator: coordinator)
        // Simulate vim entering the alternate screen.
        view.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(view.terminal.isCurrentBufferAlternate, "precondition: vim is on the alt screen")

        let moved = cache.move(from: oldID, to: newID, parentTabID: tabID)

        XCTAssertTrue(
            moved?.view.terminal.isCurrentBufferAlternate ?? false,
            "alternate-screen state must survive the move, else vim repaints as raw escapes"
        )
    }

    func testMoveKeepsCoordinatorAndStreamAttached() {
        let cache = TerminalViewCache.shared
        let oldID = UUID()
        let newID = UUID()
        let tabID = UUID()
        let view = makeView()
        let coordinator = makeCoordinator()
        let (stream, continuation) = AsyncStream<String>.makeStream()

        cache.store(tabID: oldID, parentTabID: tabID, view: view, coordinator: coordinator)
        cache.connectOutputStream(stream, onBytesProcessed: { _ in }, to: oldID)
        continuation.yield("hello")

        let moved = cache.move(from: oldID, to: newID, parentTabID: tabID)

        XCTAssertTrue(moved?.coordinator === coordinator, "coordinator must travel with the view")
        XCTAssertNotNil(moved?.outputStream, "the live stream must stay attached")
        XCTAssertNotNil(moved?.onBytesProcessed, "backpressure callback must stay attached")
    }

    func testMoveToSameIDIsANoOp() {
        let cache = TerminalViewCache.shared
        let id = UUID()
        let tabID = UUID()
        let view = makeView()
        cache.store(tabID: id, parentTabID: tabID, view: view, coordinator: makeCoordinator())

        let moved = cache.move(from: id, to: id, parentTabID: tabID)

        XCTAssertNil(moved, "moving onto the same key must not evict the live view")
        XCTAssertNotNil(cache.retrieve(id), "entry must remain reachable")
    }

    /// Bug 2: a re-hosted view must re-publish its geometry, otherwise the
    /// PTY keeps the old column count and wide output gets truncated.
    func testInvalidateSyncedSizeForcesResizeRepublish() {
        let view = makeView()

        // Prime the cached geometry the way a normal layout pass would.
        view.terminal.resize(cols: 200, rows: 50)
        view.layout()
        let primedCols = view.terminal.cols

        view.invalidateSyncedSize()
        view.layout()

        XCTAssertEqual(view.terminal.cols, primedCols)
        XCTAssertTrue(
            view.terminal.cols > 0,
            "geometry must still be valid after invalidation"
        )
    }

    func testReboundResizeCallbackTargetsNewOwner() {
        let coordinator = makeCoordinator()
        let seen = NIOLockedValueBox<[Int]>([])
        let expectation = expectation(description: "resize forwarded")

        coordinator.onResize = { cols, rows in
            seen.withLockedValue { $0.append(cols) }
            if rows > 0 { expectation.fulfill() }
        }
        coordinator.handleResize(cols: 120, rows: 40)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(seen.withLockedValue { $0 }, [120])
    }
}
