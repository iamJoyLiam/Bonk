//
//  SSHModelsTests.swift
//  BonkTests
//

import XCTest
@testable import Bonk

#if os(macOS)
private final class TestDataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    func append(_ value: Data) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var data: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
#endif

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

    #if os(macOS)
        func testOpenSSHResponderUsesHostScopedPassword() {
            let sink = TestDataSink()
            let responder = OpenSSHAuthPromptResponder(
                credentials: [
                    OpenSSHPasswordCredential(
                        username: "xuhaibo",
                        host: "jmp.allinmd.cn",
                        password: "secret"
                    ),
                ],
                allowInteractivePrompt: false,
                allowUnscopedPassword: false,
                write: sink.append
            )

            responder.observe(
                Data("xuhaibo@jmp.allinmd.cn's password: ".utf8)
            )

            XCTAssertEqual(
                sink.data.compactMap { String(data: $0, encoding: .utf8) },
                ["secret\n"]
            )
        }

        func testOpenSSHResponderDoesNotSendTargetPasswordToUnscopedJumpPrompt() {
            let sink = TestDataSink()
            let responder = OpenSSHAuthPromptResponder(
                credentials: [
                    OpenSSHPasswordCredential(
                        username: "target",
                        host: "target.internal",
                        password: "target-secret"
                    ),
                ],
                allowInteractivePrompt: false,
                allowUnscopedPassword: false,
                write: sink.append
            )

            responder.observe(Data("Password: ".utf8))

            XCTAssertTrue(sink.data.isEmpty)
        }
    #endif
}
