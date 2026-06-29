//
//  FocusManagerTests.swift
//  BonkTests
//
//  Tests for FocusManager functionality.
//

import XCTest
@testable import Bonk

@MainActor
final class FocusManagerTests: XCTestCase {

    var focusManager: FocusManager!

    override func setUp() {
        super.setUp()
        focusManager = FocusManager.shared
    }

    // MARK: - Initial State

    func testInitialFocusedPaneID() {
        XCTAssertNil(focusManager.focusedPaneID)
    }

    // MARK: - Focus Operations

    func testFocusPane() {
        let paneID = UUID()
        focusManager.focus(paneID)
        XCTAssertEqual(focusManager.focusedPaneID, paneID)
    }

    func testIsFocused() {
        let paneID = UUID()
        focusManager.focus(paneID)
        XCTAssertTrue(focusManager.isFocused(paneID))
        XCTAssertFalse(isFocused(UUID()))
    }

    private func isFocused(_ paneID: UUID) -> Bool {
        focusManager.focusedPaneID == paneID
    }
}
