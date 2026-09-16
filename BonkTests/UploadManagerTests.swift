//
//  UploadManagerTests.swift
//  BonkTests
//
//  Tests for UploadManager functionality.
//

@testable import Bonk
import XCTest

@MainActor
final class UploadManagerTests: XCTestCase {
    var uploadManager: UploadManager!

    override func setUp() {
        super.setUp()
        uploadManager = UploadManager.shared
    }

    // MARK: - Initial State

    func testInitialUploadState() {
        let tabID = UUID()
        XCTAssertNil(uploadManager.progress(for: tabID))
        XCTAssertNil(uploadManager.message(for: tabID))
    }

    // MARK: - State Management

    func testClearState() {
        let tabID = UUID()
        // Set some state
        uploadManager.setMessage("Test message", for: tabID)

        // Clear state for this tab
        uploadManager.clear(tabID: tabID)

        // Verify state is cleared
        XCTAssertNil(uploadManager.progress(for: tabID))
        XCTAssertNil(uploadManager.message(for: tabID))
    }

    // MARK: - Per-tab isolation

    func testPerTabIsolation() {
        let tabA = UUID()
        let tabB = UUID()

        uploadManager.setMessage("uploading in A", for: tabA)

        // Tab B must not see tab A's state
        XCTAssertNil(uploadManager.message(for: tabB))
        XCTAssertNil(uploadManager.progress(for: tabB))
        XCTAssertEqual(uploadManager.message(for: tabA), "uploading in A")

        // Clearing A must not touch B
        uploadManager.setMessage("uploading in B", for: tabB)
        uploadManager.clear(tabID: tabA)
        XCTAssertNil(uploadManager.message(for: tabA))
        XCTAssertEqual(uploadManager.message(for: tabB), "uploading in B")

        uploadManager.clear(tabID: tabB)
    }
}
