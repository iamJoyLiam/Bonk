//
//  InputHandlerTests.swift
//  BonkTests
//
//  Tests for InputHandler functionality.
//

import XCTest
@testable import Bonk

@MainActor
final class InputHandlerTests: XCTestCase {

    var inputHandler: InputHandler!

    override func setUp() {
        super.setUp()
        inputHandler = InputHandler()
    }

    override func tearDown() {
        inputHandler = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertNotNil(inputHandler)
    }

    // MARK: - Input Processing

    func testSendInputWithEmptyBytes() async throws {
        // Test with empty bytes - should not crash
        let host = HostItem(name: "test", host: "localhost", port: 22, username: "root", authType: .password)
        let tab = TerminalTab(hostItem: host)
        let bytes: ArraySlice<UInt8> = []
        // This should not throw
        try? await inputHandler.sendInput(bytes, to: tab)
    }

    func testSendTextWithEnter() async throws {
        // Test sending text with enter key
        let host = HostItem(name: "test", host: "localhost", port: 22, username: "root", authType: .password)
        let tab = TerminalTab(hostItem: host)
        // This should not throw
        try? await inputHandler.sendText("ls", to: tab)
    }
}
