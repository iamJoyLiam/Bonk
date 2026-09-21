//
//  SSHRecoveryTests.swift
//  BonkTests — network-recovery failure path (no live server needed).
//
//  Covers the supervisor contract for event-driven recovery:
//  1. pre-probed dead  -> reconnect immediately, no second probe.
//  2. pre-probed alive -> resolve ready, no reconnect (never kill live).
//  3. normal path      -> retry loop + backoff sequence intact.
//

import XCTest
@testable import Bonk

final class SSHRecoveryTests: XCTestCase {
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var probe = 0
        private(set) var reconnect = 0
        private(set) var probedAlive = 0
        private(set) var attempts: [Int] = []
        func incProbe() { lock.lock(); probe += 1; lock.unlock() }
        func incReconnect() { lock.lock(); reconnect += 1; lock.unlock() }
        func incAlive() { lock.lock(); probedAlive += 1; lock.unlock() }
        func recordAttempt(_ n: Int) { lock.lock(); attempts.append(n); lock.unlock() }
    }

    private func waitIdle(_ supervisor: SSHConnectionSupervisor, timeout: TimeInterval = 20) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await supervisor.currentState() == .idle { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await supervisor.currentState() == .idle
    }

    func testNetworkRecoveryDeadSkipsProbeAndReconnectsImmediately() async {
        let supervisor = SSHConnectionSupervisor()
        let counter = CallCounter()
        await supervisor.configure(
            host: "test", engine: "test", maxAttempts: 3,
            probe: { counter.incProbe(); return false },
            reconnect: { counter.incReconnect(); return true },
            onProbedAlive: { counter.incAlive() }
        )
        let start = Date()
        await supervisor.requestRecovery(reason: .networkChanged, preProbed: .dead)
        let finished = await waitIdle(supervisor)
        XCTAssertTrue(finished, "pipeline did not finish")
        // No second probe burned its 5s budget; first reconnect immediate.
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(counter.probe, 0)
        XCTAssertEqual(counter.reconnect, 1)
        XCTAssertLessThan(elapsed, 5.0)
    }

    func testNetworkRecoveryAliveResolvesWithoutReconnect() async {
        let supervisor = SSHConnectionSupervisor()
        let counter = CallCounter()
        await supervisor.configure(
            host: "test", engine: "test", maxAttempts: 3,
            probe: { counter.incProbe(); return true },
            reconnect: { counter.incReconnect(); return true },
            onProbedAlive: { counter.incAlive() }
        )
        await supervisor.requestRecovery(reason: .networkChanged, preProbed: .alive)
        let finished = await waitIdle(supervisor)
        XCTAssertTrue(finished, "pipeline did not finish")
        // Live transport is never killed: no probe, no reconnect.
        XCTAssertEqual(counter.probe, 0)
        XCTAssertEqual(counter.reconnect, 0)
        XCTAssertEqual(counter.probedAlive, 1)
    }

    func testNormalPathKeepsRetryLoopAndBackoff() async {
        let supervisor = SSHConnectionSupervisor()
        let counter = CallCounter()
        await supervisor.configure(
            host: "test", engine: "test", maxAttempts: 3,
            probe: { counter.incProbe(); return false },
            reconnect: { counter.incReconnect(); return false },
            onProbedAlive: { counter.incAlive() },
            onReconnecting: { attempt, _ in counter.recordAttempt(attempt) }
        )
        // No context: legacy path probes, then retries 1,2,3 with backoff.
        await supervisor.requestRecovery(reason: .writeFailed)
        let finished = await waitIdle(supervisor)
        XCTAssertTrue(finished, "pipeline did not finish")
        XCTAssertEqual(counter.probe, 1)
        XCTAssertEqual(counter.reconnect, 3)
        XCTAssertEqual(counter.attempts, [1, 2, 3])
    }
}
