import XCTest
@testable import Bonk
import os

final class SSHConnectionSupervisorTests: XCTestCase {
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
}

private actor Counter {
    private var count: Int = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}
