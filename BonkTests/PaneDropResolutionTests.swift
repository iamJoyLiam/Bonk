//
//  PaneDropResolutionTests.swift
//  BonkTests
//
//  A drop target is only reachable if it is the hit view or an **ancestor** of
//  it. AppKit starts from the view the window hit-tests at the drag location and
//  walks up looking for a view that registered for the dragged type.
//
//  The pane used to place its drop registration in a sibling overlay that
//  returned nil from `hitTest`. A sibling is not an ancestor, so the walk could
//  never reach it and the pane was never a drop target.
//
//  These tests pin the two halves of the invariant that the fix must satisfy:
//  the terminal keeps every normal interaction, AND a drop still resolves. The
//  second half is what a naive "return self from hitTest" would break, so it is
//  asserted as a distinct property rather than folded into the first.
//

import AppKit
import Testing
import XCTest
@testable import Bonk

/// An ordinary view that accepts hits — stands in for the terminal.
private final class TerminalProbeView: NSView {}

/// Reproduces the shape the pane used to have: a drop overlay that registers
/// for dragged types and returns nil from `hitTest`.
///
/// This used to be `DragDropNSView` itself. That type is deleted, which is the
/// primary guarantee — the broken shape cannot be reintroduced by accident,
/// because referring to it no longer compiles. The shape is kept here as a local
/// stand-in so the *rule* it broke stays documented and testable.
private final class NilHitDropOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("unused") }
    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func draggingEntered(_: NSDraggingInfo) -> NSDragOperation { .copy }
}

@MainActor
final class PaneDropResolutionTests: XCTestCase {

    private let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = nil }
        windows = []
        try await super.tearDown()
    }

    private func makeContainer() -> NSView {
        let container = NSView(frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = container
        windows.append(window)
        return container
    }

    /// Resolve a drop the way AppKit does: hit-test, then walk up for a view
    /// that registered for the dragged type.
    private func resolveDropTarget(in container: NSView, at point: NSPoint) -> NSView? {
        guard let hit = container.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let view = candidate {
            if !view.registeredDraggedTypes.isEmpty { return view }
            candidate = view.superview
        }
        return nil
    }

    private func identity(of view: NSView?) -> String {
        guard let view else { return "nil" }
        if view is NilHitDropOverlay { return "NilHitDropOverlay" }
        if view is TerminalProbeView { return "terminal" }
        return String(describing: type(of: view))
    }

    // MARK: - The regression

    /// The overlay shape the pane used to have.
    ///
    /// The drop registration lives in a **sibling** overlay whose `hitTest`
    /// returns nil, so the window hit test yields the terminal and the ancestor
    /// walk never reaches the registered view. This is the bug, asserted
    /// directly: `dropReachable` is false.
    func testSiblingOverlayIsNotAReachableDropTarget() throws {
        let container = makeContainer()
        container.addSubview(TerminalProbeView(frame: frame))
        container.addSubview(NilHitDropOverlay(frame: frame)) // hitTest -> nil
        container.layoutSubtreeIfNeeded()

        let center = NSPoint(x: 200, y: 150)
        let hit = container.hitTest(center)
        let target = resolveDropTarget(in: container, at: center)

        XCTAssertEqual(identity(of: hit), "terminal",
                       "the overlay must not steal the hit from the terminal")
        XCTAssertNil(target,
                     """
                     A drop target must be the hit view or an ancestor of it. A sibling \
                     overlay that returns nil from hitTest is neither, so the pane is \
                     never a drop target and draggingEntered never fires.
                     """)
    }

    /// An overlay that returns nil also hides its own subviews from hit testing.
    ///
    /// Worth pinning because it is the same root cause wearing a different hat:
    /// an unconditional `nil` is not "pass through", it is "this view and
    /// anything inside it are invisible to hit testing".
    func testNilHitTestHidesItsOwnSubviews() throws {
        let container = makeContainer()
        let dropView = NilHitDropOverlay(frame: frame)
        dropView.addSubview(TerminalProbeView(frame: frame))
        container.addSubview(dropView)
        container.layoutSubtreeIfNeeded()

        let center = NSPoint(x: 200, y: 150)
        let hit = container.hitTest(center)
        XCTAssertNotEqual(identity(of: hit), "terminal",
                          """
                          A view returning nil from hitTest cannot contain anything \
                          that gets hit either — the walk never reaches its subviews.
                          """)
    }

    // MARK: - The shape the fix must produce

    /// Drop registration on the container, no overlay: both halves hold.
    ///
    /// The terminal is still the hit view, so mouse, keyboard, scroll and
    /// selection are untouched. The container is an ancestor of the terminal, so
    /// the walk reaches it and the drop resolves.
    func testContainerRegistrationKeepsTerminalInteractionAndReachesDrop() throws {
        let container = makeContainer()
        container.addSubview(TerminalProbeView(frame: frame))
        container.registerForDraggedTypes([.fileURL, .string])
        container.layoutSubtreeIfNeeded()

        let center = NSPoint(x: 200, y: 150)
        let hit = container.hitTest(center)
        let target = resolveDropTarget(in: container, at: center)

        XCTAssertEqual(identity(of: hit), "terminal",
                       "normal interaction must stay terminal-owned")
        XCTAssertFalse(identity(of: target) == "nil",
                       "a drop must still resolve through the ancestor walk")
    }

    /// The anti-regression guard for the tempting one-line "fix".
    ///
    /// An overlay that returns `self` *does* become a reachable drop target — and
    /// in doing so it becomes the hit view for everything, so the terminal stops
    /// receiving clicks, scroll, and drag-selection across the whole pane. A
    /// drop that works by stealing the terminal is not a fix.
    func testReturningSelfWouldStealTerminalInteraction() throws {
        let container = makeContainer()
        container.addSubview(TerminalProbeView(frame: frame))
        container.addSubview(SelfHitDropOverlay(frame: frame))
        container.layoutSubtreeIfNeeded()

        let center = NSPoint(x: 200, y: 150)
        let hit = container.hitTest(center)
        let target = resolveDropTarget(in: container, at: center)

        XCTAssertEqual(identity(of: target), "SelfHitDropOverlay",
                       "returning self does make the drop reachable — which is the trap")
        XCTAssertNotEqual(identity(of: hit), "terminal",
                          """
                          ...and it takes every click, scroll and selection with it. This is \
                          why "return self" is not the fix: it trades a dead drop for a \
                          dead terminal.
                          """)
    }
}

// MARK: - Supplementary wiring guard
//
// STRUCTURAL, NOT BEHAVIOURAL.
//
// The behavioural tests above each build their own view hierarchy, so they
// characterise AppKit's resolution rule rather than this app's wiring. The
// behavioural coverage of *wiring* is that the overlay type is deleted: no
// module can register a drop target in a nil-hit sibling because the type does
// not exist.
//
// What that does not catch is someone deleting the `.onDrop` from the pane.
// SwiftUI's drop modifiers cannot be exercised from a headless test, so this
// source assertion exists purely to fail on that removal. It is deliberately
// labelled so it is never mistaken for behavioural evidence.

@MainActor
final class PaneDropWiringGuardTests: XCTestCase {
    func testPaneRegistersDropsOnItsContainer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Bonk/Views/Terminal/Tab/SplitPane/PaneTerminalView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".onDrop("),
                      "the pane must register its drop target on its own container")
        XCTAssertTrue(source.contains("PaneDropDelegate("),
                      "the pane must use the router-backed delegate")

        // Assert the *properties* that made the old shape broken, not the name
        // of the type that had them. An earlier version of this guard checked
        // for the identifier "DragDropView" and a mutation that restored the
        // same broken shape under a different name sailed straight through.
        XCTAssertFalse(source.contains("registerForDraggedTypes"),
                       """
                       the pane must not do its own native drop registration: a view that                        registers for dragged types in a sibling of the terminal is never                        reachable as a drop target
                       """)
        XCTAssertFalse(source.contains("func hitTest"),
                       """
                       the pane must not override hitTest: returning nil hides the view and                        its subviews, and returning self steals the terminal's clicks and scroll
                       """)
    }
}

/// A drop overlay that returns itself — the tempting but wrong fix.
///
/// It registers for dragged types, exactly as a real drop overlay must, so the
/// comparison is meaningful: this shape *does* become a reachable drop target,
/// and that is precisely the problem.
private final class SelfHitDropOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
    override func draggingEntered(_: NSDraggingInfo) -> NSDragOperation { .copy }
}
