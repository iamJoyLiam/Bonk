//
//  TabReorderTests.swift
//  BonkTests
//
//  A dragged tab takes the slot under the pointer. Neighbors slide one way
//  to open it. Dropping on a neighbor is not an exchange of the two.
//

import XCTest
@testable import Bonk

final class TabReorderTests: XCTestCase {
    func testDraggingRightLandsOnThatSlot() {
        XCTAssertEqual(TabReorder.destination(start: 0, translation: 100, width: 100, count: 3), 1)
        XCTAssertEqual(TabReorder.destination(start: 0, translation: 160, width: 100, count: 3), 2)
    }

    func testDraggingLeftLandsOnThatSlot() {
        XCTAssertEqual(TabReorder.destination(start: 2, translation: -120, width: 100, count: 3), 1)
        XCTAssertEqual(TabReorder.destination(start: 2, translation: -250, width: 100, count: 3), 0)
    }

    func testDestinationStaysInsideTheStrip() {
        XCTAssertEqual(TabReorder.destination(start: 0, translation: -80, width: 100, count: 3), 0)
        XCTAssertEqual(TabReorder.destination(start: 2, translation: 400, width: 100, count: 3), 2)
    }

    func testNeighborsSlideOutOfTheGap() {
        // [A, B, C], A dragged onto C's slot. B and C slide left.
        XCTAssertEqual(TabReorder.neighborShift(index: 1, start: 0, destination: 2), -1)
        XCTAssertEqual(TabReorder.neighborShift(index: 2, start: 0, destination: 2), -1)
        XCTAssertEqual(TabReorder.neighborShift(index: 0, start: 0, destination: 2), 0)

        // C dragged onto A's slot. A and B slide right.
        XCTAssertEqual(TabReorder.neighborShift(index: 0, start: 2, destination: 0), 1)
        XCTAssertEqual(TabReorder.neighborShift(index: 1, start: 2, destination: 0), 1)
        XCTAssertEqual(TabReorder.neighborShift(index: 2, start: 2, destination: 0), 0)
    }

    func testDownwardDragLocksToSplitAndDoesNotReorder() {
        let reorder = AppStyle.spacingM
        let split = AppStyle.tabHeight
        XCTAssertEqual(
            TabReorder.intent(width: 4, height: 10, decided: .pending, reorderDistance: reorder, splitDistance: split),
            .pending
        )
        XCTAssertEqual(
            TabReorder.intent(width: 30, height: 8, decided: .pending, reorderDistance: reorder, splitDistance: split),
            .reorder
        )
        XCTAssertEqual(
            TabReorder.intent(width: 6, height: split, decided: .pending, reorderDistance: reorder, splitDistance: split),
            .split
        )
        XCTAssertEqual(
            TabReorder.intent(width: 4, height: 40, decided: .reorder, reorderDistance: reorder, splitDistance: split),
            .reorder
        )
    }
}
