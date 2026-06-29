//
//  HostItemTests.swift
//  BonkTests
//
//  Tests for HostItem functionality.
//

import XCTest
@testable import Bonk

final class HostItemTests: XCTestCase {

    // MARK: - Initialization

    func testHostItemInitialization() {
        let host = HostItem(
            name: "Test Server",
            host: "192.168.1.1",
            port: 22,
            username: "root",
            authType: .password
        )

        XCTAssertEqual(host.name, "Test Server")
        XCTAssertEqual(host.host, "192.168.1.1")
        XCTAssertEqual(host.port, 22)
        XCTAssertEqual(host.username, "root")
        XCTAssertEqual(host.authType, .password)
        XCTAssertFalse(host.isFavorite)
        XCTAssertNil(host.lastConnectedAt)
    }

    // MARK: - Auth Type

    func testPasswordAuthType() {
        let host = HostItem(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "root",
            authType: .password
        )
        XCTAssertEqual(host.authType, .password)
        XCTAssertEqual(host.authTypeRaw, "password")
    }

    func testPrivateKeyAuthType() {
        let host = HostItem(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "root",
            authType: .privateKey
        )
        XCTAssertEqual(host.authType, .privateKey)
        XCTAssertEqual(host.authTypeRaw, "privateKey")
    }

    // MARK: - Favorite

    func testFavoriteDefault() {
        let host = HostItem(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "root",
            authType: .password
        )
        XCTAssertFalse(host.isFavorite)
    }

    // MARK: - Sort Order

    func testSortOrderDefault() {
        let host = HostItem(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "root",
            authType: .password
        )
        XCTAssertEqual(host.sortOrder, 0)
    }
}
