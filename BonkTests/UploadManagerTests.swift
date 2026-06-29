//
//  UploadManagerTests.swift
//  BonkTests
//
//  Tests for UploadManager functionality.
//

import XCTest
@testable import Bonk

@MainActor
final class UploadManagerTests: XCTestCase {

    var uploadManager: UploadManager!

    override func setUp() {
        super.setUp()
        uploadManager = UploadManager.shared
    }

    // MARK: - Initial State

    func testInitialUploadState() {
        XCTAssertNil(uploadManager.uploadProgress)
        XCTAssertNil(uploadManager.dropMessage)
    }

    // MARK: - State Management

    func testClearState() {
        // Set some state
        uploadManager.dropMessage = "Test message"
        uploadManager.uploadProgress = 0.5

        // Clear state
        uploadManager.clearState()

        // Verify state is cleared
        XCTAssertNil(uploadManager.dropMessage)
        XCTAssertNil(uploadManager.uploadProgress)
    }
}
