//
//  SessionManagerTests.swift
//  BonkTests
//
//  Tests for SessionManager core functionality.
//

import XCTest
@testable import Bonk

@MainActor
final class SessionManagerTests: XCTestCase {

    var sessionManager: SessionManager!

    override func setUp() {
        super.setUp()
        sessionManager = SessionManager()
    }

    override func tearDown() {
        sessionManager = nil
        super.tearDown()
    }

    // MARK: - Tab Management

    func testInitialTabsAreEmpty() {
        XCTAssertTrue(sessionManager.tabs.isEmpty)
    }

    func testActiveTabIsNilInitially() {
        XCTAssertNil(sessionManager.activeTab)
    }

    func testActiveTabIDIsNilInitially() {
        XCTAssertNil(sessionManager.activeTabID)
    }

    // MARK: - Broadcast

    func testInitialBroadcastState() {
        XCTAssertFalse(sessionManager.isGlobalBroadcastEnabled)
    }

    func testToggleGlobalBroadcast() {
        XCTAssertFalse(sessionManager.isGlobalBroadcastEnabled)
        sessionManager.toggleGlobalBroadcast()
        XCTAssertTrue(sessionManager.isGlobalBroadcastEnabled)
        sessionManager.toggleGlobalBroadcast()
        XCTAssertFalse(sessionManager.isGlobalBroadcastEnabled)
    }

    // MARK: - Error Handling

    func testInitialErrorState() {
        XCTAssertFalse(sessionManager.showError)
        XCTAssertNil(sessionManager.lastError)
    }
}
