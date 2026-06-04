//
//  SSHModelsTests.swift
//  GhostShellTests
//

import XCTest
@testable import GhostShell

final class SSHModelsTests: XCTestCase {

    func testConnectedState() {
        XCTAssertTrue(SSHConnectionState.connected.isConnected)
        XCTAssertFalse(SSHConnectionState.disconnected.isConnected)
        XCTAssertFalse(SSHConnectionState.connecting.isConnected)
        XCTAssertFalse(SSHConnectionState.reconnecting(attempt: 1, maxAttempts: 3).isConnected)
    }

    func testColorName() {
        XCTAssertEqual(SSHConnectionState.connected.colorName, "green")
        XCTAssertEqual(SSHConnectionState.connecting.colorName, "yellow")
        XCTAssertEqual(SSHConnectionState.disconnected.colorName, "gray")
        XCTAssertEqual(SSHConnectionState.reconnecting(attempt: 1, maxAttempts: 3).colorName, "yellow")
    }

    func testServiceErrorDescriptions() {
        XCTAssertNotNil(SSHServiceError.alreadyConnected.errorDescription)
        XCTAssertNotNil(SSHServiceError.notConnected.errorDescription)
        XCTAssertNotNil(SSHServiceError.hostKeyMismatch(expected: "a", received: "b").errorDescription)
        XCTAssertNotNil(SSHServiceError.connectionFailed("reason").errorDescription)
        XCTAssertNotNil(SSHServiceError.reconnectExhausted(attempts: 3).errorDescription)
    }

    func testConnectionConfigDefaults() {
        let config = SSHConnectionConfig(
            host: "example.com",
            username: "user",
            authMethod: .password("pw")
        )
        XCTAssertEqual(config.port, 22)
        XCTAssertEqual(config.maxReconnectAttempts, 5)
    }
}
