//
//  PaneDropRouterTests.swift
//  BonkTests
//
//  The decisions a terminal pane makes about a drag.
//
//  These used to live inside `DragDropNSView` as private methods, unreachable
//  from a test. They are now pure functions, so the behaviour that the split
//  indicator, the split-pane routing and the SFTP upload all depend on can be
//  checked directly instead of inferred.
//

import CoreGraphics
import Foundation
import Testing
@testable import Bonk

@Suite("Pane Drop Router Tests")
struct PaneDropRouterTests {

    private let size = CGSize(width: 400, height: 300)

    // MARK: - Position

    /// The pointer's nearest edge decides the split direction.
    @Test("Position resolves to the nearest edge")
    func positionIsNearestEdge() {
        let nearLeft = PaneDropRouter.position(for: CGPoint(x: 10, y: 150), in: size)
        let nearRight = PaneDropRouter.position(for: CGPoint(x: 390, y: 150), in: size)
        let nearTop = PaneDropRouter.position(for: CGPoint(x: 200, y: 290), in: size)
        let nearBottom = PaneDropRouter.position(for: CGPoint(x: 200, y: 10), in: size)

        #expect(nearLeft == .left)
        #expect(nearRight == .right)
        #expect(nearTop == .top)
        #expect(nearBottom == .bottom)
    }

    /// A degenerate size must not divide by zero or trap.
    @Test("A zero-size pane falls back rather than trapping")
    func degenerateSizeFallsBack() {
        let zero = CGSize(width: 0, height: 0)
        #expect(PaneDropRouter.position(for: CGPoint(x: 5, y: 5), in: zero) == .right)
    }

    // MARK: - Payload classification

    /// Only a parseable UUID is a tab. Text dragged out of a terminal is plain
    /// text too, and must never be mistaken for a tab.
    @Test("Only a parseable UUID is treated as a tab")
    func tabIDRequiresAUUID() {
        let uuid = UUID()
        #expect(PaneDropRouter.tabID(fromUUIDString: uuid.uuidString) == uuid)
        #expect(PaneDropRouter.tabID(fromUUIDString: "not-a-uuid") == nil)
        #expect(PaneDropRouter.tabID(fromUUIDString: "") == nil)
        #expect(PaneDropRouter.tabID(fromUUIDString: nil) == nil)
        // Selected text that happens to be long must not parse.
        #expect(PaneDropRouter.tabID(fromUUIDString: "hello world this is selected text") == nil)
    }

    // MARK: - Indicator

    /// The indicator is for splitting only: tab drags that are not a self-drop.
    @Test("The indicator shows only for a non-self tab drag")
    func indicatorOnlyForNonSelfTabDrag() {
        let source = UUID()
        let current = UUID()

        #expect(PaneDropRouter.showsIndicator(for: .tab(source), currentTabID: current))
        #expect(!PaneDropRouter.showsIndicator(for: .tab(current), currentTabID: current),
                "a tab dropped on itself must not show a split indicator")
        #expect(!PaneDropRouter.showsIndicator(for: .files([URL(fileURLWithPath: "/tmp/a")]), currentTabID: current),
                "files upload; they do not split, so no indicator")
        #expect(!PaneDropRouter.showsIndicator(for: nil, currentTabID: current))
    }

    // MARK: - Routing

    /// A tab drag splits at the resolved position.
    @Test("A tab drag routes to a split at the pointer's edge")
    func tabDragRoutesToSplit() {
        let source = UUID()
        let action = PaneDropRouter.route(
            payload: .tab(source),
            currentTabID: UUID(),
            position: .left
        )
        #expect(action == .moveTab(source: source, position: .left))
    }

    /// A self-drop is rejected rather than splitting a tab against itself.
    @Test("A self-drop is rejected")
    func selfDropIsRejected() {
        let current = UUID()
        #expect(PaneDropRouter.route(payload: .tab(current), currentTabID: current, position: .right) == .reject)
    }

    /// Files route to the upload callback.
    @Test("A file drag routes to upload")
    func fileDragRoutesToUpload() {
        let urls = [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")]
        #expect(PaneDropRouter.route(payload: .files(urls), currentTabID: UUID(), position: .right)
                == .uploadFiles(urls))
    }

    /// File priority is preserved: a drag carrying both uploads the files.
    ///
    /// This mirrors the original `performDragOperation`, which checked files
    /// before the tab UUID.
    @Test("Files take priority over a tab when a drag carries both")
    func filesTakePriorityOverTab() {
        let urls = [URL(fileURLWithPath: "/tmp/one")]
        let payload = PaneDropPayload.files(urls)
        #expect(PaneDropRouter.route(payload: payload, currentTabID: UUID(), position: .right)
                == .uploadFiles(urls))
    }

    /// An empty file list is not an upload.
    @Test("An empty file list is rejected")
    func emptyFileListRejected() {
        #expect(PaneDropRouter.route(payload: .files([]), currentTabID: UUID(), position: .right) == .reject)
    }

    /// Nothing recognisable is rejected, so `performDrop` returns false and
    /// AppKit continues looking for another target.
    @Test("An unreadable payload is rejected")
    func unreadablePayloadRejected() {
        #expect(PaneDropRouter.route(payload: nil, currentTabID: UUID(), position: .right) == .reject)
    }
}
