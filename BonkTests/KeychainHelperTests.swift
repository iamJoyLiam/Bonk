//
//  KeychainHelperTests.swift
//  BonkTests
//
//  Tests for KeychainHelper functionality.
//

import XCTest
@testable import Bonk

final class KeychainHelperTests: XCTestCase {

    let testKey = "test-keychain-key"
    let testValue = "test-password-123"

    override func tearDown() {
        // Clean up test key
        KeychainHelper.delete(for: testKey)
        super.tearDown()
    }

    // MARK: - Basic Operations

    func testSetAndGet() {
        KeychainHelper.set(testValue, for: testKey)
        let retrieved = KeychainHelper.get(for: testKey)
        XCTAssertEqual(retrieved, testValue)
    }

    func testGetReturnsNilForNonexistentKey() {
        let result = KeychainHelper.get(for: "nonexistent-key")
        XCTAssertNil(result)
    }

    func testDelete() {
        KeychainHelper.set(testValue, for: testKey)
        XCTAssertNotNil(KeychainHelper.get(for: testKey))

        KeychainHelper.delete(for: testKey)
        XCTAssertNil(KeychainHelper.get(for: testKey))
    }

    func testOverwrite() {
        KeychainHelper.set("first", for: testKey)
        KeychainHelper.set("second", for: testKey)
        let result = KeychainHelper.get(for: testKey)
        XCTAssertEqual(result, "second")
    }

    // MARK: - Secure Bytes

    func testSetAndGetSecure() {
        let secureValue: SecureBytes = [0x01, 0x02, 0x03]
        KeychainHelper.setSecure(secureValue, for: testKey)
        let retrieved = KeychainHelper.getSecure(for: testKey)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, secureValue)
    }

    func testGetSecureReturnsNilForNonexistentKey() {
        let result = KeychainHelper.getSecure(for: "nonexistent-key")
        XCTAssertNil(result)
    }
}
