//
//  TerminalHostHitTests.swift
//  BonkTests
//
//  The overlay thumb is parked in the gutter, outside the terminal view.
//  A click there has to reach the scroller or the thumb cannot be dragged.
//

import AppKit
import XCTest
@testable import Bonk

final class TerminalHostHitTests: XCTestCase {
    func testGutterClickReachesTheScroller() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let host = TerminalHostView(fill: .black)
        host.frame = NSRect(x: 10, y: 10, width: 200, height: 100)
        parent.addSubview(host)

        let terminal = NSView(frame: NSRect(x: 8, y: 4, width: 180, height: 92))
        host.addSubview(terminal)
        let scroller = NSScroller(frame: NSRect(x: 180, y: 0, width: 12, height: 92))
        scroller.isEnabled = true
        scroller.isHidden = false
        terminal.addSubview(scroller)

        let local = NSPoint(x: 8 + 180 + 6, y: 4 + 46)
        XCTAssertTrue(TerminalHostView.scroller(in: host, containing: local) === scroller)

        let hitPoint = NSPoint(x: host.frame.minX + local.x, y: host.frame.minY + local.y)
        XCTAssertTrue(host.hitTest(hitPoint) === scroller)
    }

    func testTextClickDoesNotGoToTheScroller() {
        let host = hostWithScroller()
        let text = NSPoint(x: 30, y: 40)
        XCTAssertNil(TerminalHostView.scroller(in: host, containing: text))
    }

    func testHiddenScrollerDoesNotTakeTheClick() {
        let host = hostWithScroller()
        let scroller = host.subviews[0].subviews.compactMap { $0 as? NSScroller }.first
        scroller?.isHidden = true
        let local = NSPoint(x: 8 + 180 + 6, y: 4 + 46)
        XCTAssertNil(TerminalHostView.scroller(in: host, containing: local))
    }

    private func hostWithScroller() -> TerminalHostView {
        let host = TerminalHostView(fill: .black)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let terminal = NSView(frame: NSRect(x: 8, y: 4, width: 180, height: 92))
        host.addSubview(terminal)
        let scroller = NSScroller(frame: NSRect(x: 180, y: 0, width: 12, height: 92))
        scroller.isEnabled = true
        terminal.addSubview(scroller)
        return host
    }
}
