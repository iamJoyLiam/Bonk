//
//  BroadcastManagerTests.swift
//  BonkTests
//
//  Tests for BroadcastManager functionality.
//

import XCTest
@testable import Bonk

@MainActor
final class BroadcastManagerTests: XCTestCase {

    var broadcastManager: BroadcastManager!

    override func setUp() {
        super.setUp()
        broadcastManager = BroadcastManager()
    }

    override func tearDown() {
        broadcastManager = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialBroadcastState() {
        XCTAssertFalse(broadcastManager.isEnabled)
        XCTAssertTrue(broadcastManager.targetPaneIDs.isEmpty)
        XCTAssertTrue(broadcastManager.allPaneIDs.isEmpty)
    }

    // MARK: - Toggle Operations

    func testToggleBroadcast() {
        XCTAssertFalse(broadcastManager.isEnabled)

        broadcastManager.toggle()
        XCTAssertTrue(broadcastManager.isEnabled)

        broadcastManager.toggle()
        XCTAssertFalse(broadcastManager.isEnabled)
    }

    // MARK: - Pane Management

    func testTogglePane() {
        let paneID = UUID()
        broadcastManager.allPaneIDs = [paneID]

        broadcastManager.togglePane(paneID)
        XCTAssertTrue(broadcastManager.targetPaneIDs.contains(paneID))

        broadcastManager.togglePane(paneID)
        XCTAssertFalse(broadcastManager.targetPaneIDs.contains(paneID))
    }

    func testSelectAll() {
        let paneIDs = [UUID(), UUID(), UUID()]
        broadcastManager.allPaneIDs = paneIDs

        broadcastManager.selectAll()
        XCTAssertEqual(broadcastManager.targetPaneIDs.count, paneIDs.count)
    }

    func testDeselectAll() {
        let paneIDs = [UUID(), UUID(), UUID()]
        broadcastManager.allPaneIDs = paneIDs
        broadcastManager.selectAll()

        broadcastManager.deselectAll()
        XCTAssertTrue(broadcastManager.targetPaneIDs.isEmpty)
    }

    func testIsTarget() {
        let paneID = UUID()
        broadcastManager.allPaneIDs = [paneID]

        XCTAssertFalse(broadcastManager.isTarget(paneID))

        broadcastManager.togglePane(paneID)
        XCTAssertTrue(broadcastManager.isTarget(paneID))
    }
}
