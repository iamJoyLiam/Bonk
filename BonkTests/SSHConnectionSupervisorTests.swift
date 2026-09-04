import XCTest
@testable import Bonk
import os
import NIOCore

final class SSHConnectionSupervisorTests: XCTestCase {
    // MARK: - Channel-lost error classification

    func testChannelLostClassification() {
        // SwiftNIO typed errors
        XCTAssertTrue(SSHChannelLostError.isChannelLost(ChannelError.outputClosed))
        XCTAssertTrue(SSHChannelLostError.isChannelLost(ChannelError.ioOnClosedChannel))
        XCTAssertTrue(SSHChannelLostError.isChannelLost(ChannelError.alreadyClosed))
        XCTAssertTrue(SSHChannelLostError.isChannelLost(ChannelError.eof))

        // POSIX socket death errors
        XCTAssertTrue(SSHChannelLostError.isChannelLost(POSIXError(.EPIPE)))
        XCTAssertTrue(SSHChannelLostError.isChannelLost(POSIXError(.ECONNRESET)))

        // SSH service errors
        XCTAssertTrue(SSHChannelLostError.isChannelLost(SSHServiceError.notConnected))

        // Bridged NSError path (localized description: "未能完成操作。（NIOCore.ChannelError 错误 5。）")
        let bridged = NSError(domain: "NIOCore.ChannelError", code: 5)
        XCTAssertTrue(SSHChannelLostError.isChannelLost(bridged))
        XCTAssertFalse(SSHChannelLostError.isChannelLost(NSError(domain: "Other.Domain", code: 5)))
    }

    func testIdempotentRecovery() async {
        let supervisor = SSHConnectionSupervisor()
        let probeCounter = Counter()
        let reconnectCounter = Counter()
        await supervisor.configure(
            host: "test@host:22",
            engine: "test",
            probe: { await probeCounter.increment(); return false },
            reconnect: { await reconnectCounter.increment(); try? await Task.sleep(for: .milliseconds(10)); return true },
            onProbedAlive: {}
        )
        // Sequential rapid triggers should coalesce to 1 pipeline (second call sees probing)
        await supervisor.requestRecovery(reason: .wakeProbeFailed(sleepDuration: 10))
        await supervisor.requestRecovery(reason: .channelClosed)
        await supervisor.requestRecovery(reason: .keepAliveTimeout)
        await supervisor.requestRecovery(reason: .wakeProbeFailed(sleepDuration: 10))
        try? await Task.sleep(for: .milliseconds(150))
        let probeCount = await probeCounter.value()
        let reconnectCount = await reconnectCounter.value()
        XCTAssertEqual(probeCount, 1, "idempotent: rapid triggers must produce 1 probe")
        XCTAssertEqual(reconnectCount, 1, "idempotent: 1 reconnect")
        let state = await supervisor.currentState()
        XCTAssertEqual(state, .idle, "after success should be idle")
    }

    func testPerSessionIsolation() async {
        let supervisorA = SSHConnectionSupervisor()
        let supervisorB = SSHConnectionSupervisor()
        let counterA = Counter()
        let counterB = Counter()
        await supervisorA.configure(host: "a", engine: "test", probe: { false }, reconnect: { await counterA.increment(); return true }, onProbedAlive: {})
        await supervisorB.configure(host: "b", engine: "test", probe: { false }, reconnect: { await counterB.increment(); return true }, onProbedAlive: {})
        await supervisorA.requestRecovery(reason: .channelClosed)
        try? await Task.sleep(for: .milliseconds(80))
        let stateB = await supervisorB.currentState()
        let countA = await counterA.value()
        let countB = await counterB.value()
        XCTAssertEqual(stateB, .idle)
        XCTAssertEqual(countA, 1)
        XCTAssertEqual(countB, 0)
    }

    func testProbeAliveDoesNotReconnect() async {
        let supervisor = SSHConnectionSupervisor()
        let reconnectCounter = Counter()
        await supervisor.configure(
            host: "test", engine: "test",
            probe: { true },
            reconnect: { await reconnectCounter.increment(); return true },
            onProbedAlive: {}
        )
        await supervisor.requestRecovery(reason: .wakeProbeFailed(sleepDuration: 5))
        try? await Task.sleep(for: .milliseconds(50))
        let count = await reconnectCounter.value()
        XCTAssertEqual(count, 0, "alive probe must not trigger reconnect")
        let state = await supervisor.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testBackoffOnFailure() async {
        let supervisor = SSHConnectionSupervisor()
        let attemptCounter = Counter()
        await supervisor.configure(
            host: "test", engine: "test",
            probe: { false },
            reconnect: { await attemptCounter.increment(); return false },
            onProbedAlive: {}
        )
        await supervisor.requestRecovery(reason: .channelClosed)
        try? await Task.sleep(for: .milliseconds(1500))
        let attempts = await attemptCounter.value()
        XCTAssertGreaterThanOrEqual(attempts, 2)
        await supervisor.reset()
    }

    func testReconnectingAndExhaustedCallbacks() async {
        let supervisor = SSHConnectionSupervisor()
        let reconnectingCounter = Counter()
        let exhaustedCounter = Counter()

        await supervisor.configure(
            host: "test", engine: "test",
            maxAttempts: 2,
            probe: { false },
            reconnect: { false },
            onProbedAlive: {},
            onReconnecting: { _, _ in Task { await reconnectingCounter.increment() } },
            onExhausted: { Task { await exhaustedCounter.increment() } }
        )

        await supervisor.requestRecovery(reason: .writeFailed)
        // Wait for probe (<10ms) + attempt 1 (<10ms) + backoff (1s) + attempt 2 (<10ms)
        try? await Task.sleep(for: .milliseconds(1300))

        let reconnectingCalls = await reconnectingCounter.value()
        let exhaustedCalls = await exhaustedCounter.value()

        XCTAssertEqual(reconnectingCalls, 2, "must notify onReconnecting for each attempt")
        XCTAssertEqual(exhaustedCalls, 1, "must notify onExhausted after all attempts fail")
        let state = await supervisor.currentState()
        XCTAssertEqual(state, .idle)
    }
}

private actor Counter {
    private var count: Int = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}
