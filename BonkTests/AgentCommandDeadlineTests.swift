//
//  AgentCommandDeadlineTests.swift
//  BonkTests
//
//  A command that never finishes must be terminated, and a command that is
//  merely long must not be.
//
//  The finding: the Citadel path had no bound at all. `AgentRuntime.runToolCall`
//  awaits the executor inside a non-cooperative `EventLoopFuture`, so the loop
//  was parked with no way out, and `AgentBudgetController`'s 10-minute wall
//  clock could not fire because it is only checked between iterations. The run
//  simply hung.
//
//  The obvious fix is to copy the OpenSSH transport's 30s. That is wrong, and
//  the tests here are largely about why: the agent legitimately runs
//  `npm install`, `make`, `cargo build`. Killing those at 30s would trade a hang
//  for silent breakage. So the bound is derived from the run's own wall-clock
//  budget rather than picked, and the "must not kill a healthy long task" case
//  is exercised against a real running process.
//

import Citadel
import Darwin
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import os
import Testing
@testable import Bonk

@Suite("Agent Command Deadline Tests", .serialized)
@MainActor
struct AgentCommandDeadlineTests {



    // MARK: - The bound is derived, not picked

    /// A single command may not outlive the run that contains it. If this drifts
    /// apart from the budget, either a command can consume more than its run or
    /// the deadline fires before the budget ever could — both wrong.
    @Test("The per-command bound matches the run's wall-clock budget")
    func boundMatchesTheRunBudget() {
        #expect(AgentCommandDeadline.maxLifetime == .seconds(600),
                "the bound is derived from the run budget, not chosen independently")

        // Read the budget from the real controller rather than restating it.
        let budget = AgentBudgetController()
        #expect(Duration.milliseconds(Int(budget.maxWallClockMs)) == AgentCommandDeadline.maxLifetime)
    }

    /// Explicitly not the OpenSSH figure. 30s is right for an interactive probe
    /// and wrong for a build; if someone "aligns" these, this test says why not.
    @Test("The bound is deliberately not the OpenSSH 30s")
    func notTheOpenSSHFihure() {
        #expect(AgentCommandDeadline.maxLifetime != .seconds(30))
    }

    @Test("The boundary is evaluated at the limit, not past it")
    func boundaryIsExact() {
        #expect(AgentCommandDeadline.evaluate(elapsed: .seconds(599)) == .withinBudget)
        #expect(AgentCommandDeadline.evaluate(elapsed: .seconds(600)) == .exceeded)
        #expect(AgentCommandDeadline.evaluate(elapsed: .seconds(601)) == .exceeded)
        #expect(AgentCommandDeadline.evaluate(elapsed: .zero) == .withinBudget)
        // The limit is a parameter so a test need not wait ten minutes.
        #expect(AgentCommandDeadline.evaluate(elapsed: .seconds(5), limit: .seconds(1)) == .exceeded)
        #expect(AgentCommandDeadline.evaluate(elapsed: .seconds(1), limit: .seconds(5)) == .withinBudget)
    }

    // MARK: - Production path: a command that never ends is terminated

    /// The core case, against a real server and a real subprocess that would
    /// otherwise run forever.
    @Test("A command that never finishes is terminated at the deadline")
    func neverEndingCommandIsTerminated() async throws {
        let fixture = try await makeFixture(roles: [
            (needle: "echo RUNNER", role: .runner),
            (needle: "echo DEADLINE", role: .deadline),
        ])
        defer { fixture.dispose() }

        let runner = Task {
            _ = try? await fixture.session.execute(
                "while true; do echo RUNNER; sleep 0.05; done"
            )
        }

        // A real process exists and is running.
        try await waitUntil(label: "B-WAIT-PIDS-APPEAR") { !fixture.host.spawnedPIDs.isEmpty }
        if fixture.host.spawnedPIDs.isEmpty { Issue.record(Comment(rawValue: "B-WAIT-NO-PID")) }
        let runnerPID = try await waitForPID(.runner, label: "B-WAIT-RUNNER-PID", on: fixture.host)
        try await waitUntil(label: "B-WAIT-FIRST-PID-ALIVE") { fixture.host.isAlive(runnerPID) }

        // Short deadline, so the test does not wait ten minutes.
        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        var succeeded = false
        do {
            _ = try await handle.run(
                "while true; do echo DEADLINE; sleep 0.05; done",
                deadline: .milliseconds(700)
            )
            succeeded = true
        } catch {
            succeeded = false
        }
        #expect(succeeded == false, "B-DEADLINE-SUCCEEDED")

        // The pid the *deadline* created, not the one the never-ending runner
        // created. Asserting on `spawnedPIDs.first` observes the wrong process:
        // it belongs to the other execution chain, which this deadline never had
        // any authority over, so the assertion was testing that chain instead.
        let deadlinePID = try await waitForPID(.deadline, label: "B-WAIT-DEADLINE-PID", on: fixture.host)
        #expect(deadlinePID != runnerPID, "B-WRONG-PID")
        try await waitUntil(label: "B-WAIT-DEADLINE-PID-DIES") { !fixture.host.isAlive(deadlinePID) }
        #expect(!fixture.host.isAlive(deadlinePID), "B-DEADLINE-PROCESS-STILL-ALIVE")
        runner.cancel()
    }

    /// The timeout must surface as a timeout, not as whatever the transport
    /// happened to report while the connection was torn down.
    @Test("A deadline breach surfaces as a deadline error")
    func deadlineBreachSurfacesAsDeadlineError() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }

        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        var thrown: (any Error)?
        do {
            _ = try await handle.run("while true; do sleep 0.05; done", deadline: .milliseconds(600))
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "exceeding the deadline must throw")
        if let deadlineError = thrown as? CommandDeadlineExceeded {
            #expect(deadlineError.maxLifetime == .milliseconds(600),
                    "the error must name the bound that was actually applied")
        } else {
            Issue.record(Comment(rawValue: "DIAG expected CommandDeadlineExceeded, got \(String(describing: thrown))"))
        }
    }



    // MARK: - The healthy long task is NOT killed

    /// The counterweight. A command that runs well past the interactive-probe
    /// figure must survive, as long as it stays inside its deadline. `sleep 3`
    /// against a 1s deadline would be killed; against a 30s deadline — the figure
    /// we refused to copy — it must complete.
    @Test("A long-running healthy command is not killed for being long")
    func longHealthyCommandSurvives() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }

        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        let start = ContinuousClock.now
        let buffer = try await handle.run(
            "echo started; sleep 3; echo finished", deadline: .seconds(30)
        )
        let elapsed = ContinuousClock.now - start

        let output = String(buffer: buffer)
        #expect(output.contains("started"))
        #expect(output.contains("finished"),
                "a command inside its deadline must run to completion regardless of duration")
        #expect(elapsed >= .seconds(3), "the command really did run for seconds, not milliseconds")
    }

    /// A command that finishes quickly must not be affected by the deadline at
    /// all — the watchdog must not fire spuriously.
    @Test("A quick command completes without interference from the watchdog")
    func quickCommandUnaffected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }

        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        for _ in 0..<5 {
            let buffer = try await handle.run("echo quick", deadline: .seconds(30))
            #expect(String(buffer: buffer).contains("quick"),
                    "a command well inside its deadline must not be disturbed")
        }
    }

    // MARK: - Timeout racing cancellation, late output, channel close

    /// The three interactions that would quietly re-break Finding 3.
    @Test("Cancellation still wins when the deadline is far away")
    func cancellationBeatsDeadline() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }

        let manager = AgentExecutionManager()
        let runner = Task {
            _ = try? await fixture.session.execute(
                "while true; do echo tick; sleep 0.05; done"
            )
        }
        _ = try await fixture.session.execute("true")

        // A deadline long enough that it cannot be what stops anything.
        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        let canceller = Task {
            _ = try? await handle.run("while true; do sleep 0.05; done", deadline: .seconds(600))
        }
        try await waitUntil(label: "CANCELBEATS-WAIT-NOT-CANCELLED") { handle.hasCancelled == false }
        await manager.registerActive(handle)
        await manager.cancelActive()
        await canceller.value
        #expect(handle.hasCancelled, "user cancellation must still terminate the command")
        runner.cancel()
    }

    /// Cancelling twice, and cancelling after the deadline already fired, must
    /// stay safe: the handle latches, so the second call is a no-op rather than
    /// a second teardown of a connection the user may have re-established.
    @Test("Deadline and cancellation racing is idempotent")
    func deadlineAndCancellationRaceIsIdempotent() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }

        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        let timed = Task {
            _ = try? await handle.run("while true; do sleep 0.05; done", deadline: .milliseconds(500))
        }
        // Let the deadline win, then escalate afterwards.
        await timed.value
        #expect(handle.hasCancelled, "the deadline must have closed the handle")
        await handle.close()
        await handle.close()
        #expect(handle.hasCancelled)
    }

    /// After a timeout the session must not still believe it has usable state.
    /// `close()` inside the handle marks the connection dead; a later call must
    /// not be reported as a fresh success on a torn-down connection.
    @Test("A session used after a deadline does not silently succeed")
    func sessionAfterDeadlineDoesNotFakeSuccess() async throws {
        let fixture = try await makeFixture()
        defer { fixture.dispose() }

        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        _ = try? await handle.run("while true; do sleep 0.05; done", deadline: .milliseconds(400))
        #expect(handle.hasCancelled)

        // The connection is closed, so the next exec cannot report a fresh
        // result. Either it throws or it fails the handshake — what must not
        // happen is a clean empty success, which would read as "command done".
        var succeeded = false
        do {
            let buffer = try await handle.run("echo should-not-succeed", deadline: .seconds(5))
            succeeded = String(buffer: buffer).contains("should-not-succeed")
        } catch {
            succeeded = false
        }
        #expect(succeeded == false,
                "a torn-down connection must not report a successful command")
    }

    // MARK: - Wiring

    @Test("The session's execute path applies the deadline")
    func sessionAppliesTheDeadline() throws {
        let source = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/SSH/NativeSSHSession.swift"),
            encoding: .utf8
        )
        #expect(source.contains("func run(_ command: String, deadline: Duration"),
                "the run must accept a deadline rather than being unbounded")
        #expect(source.contains("await close()"),
                "the deadline must close the connection, or the remote command keeps running")
        #expect(source.contains("AgentCommandDeadline.exceededError"))
    }

    // MARK: - Fixture

    @MainActor
    private struct Fixture {
        let session: NativeSSHSession
        let host: ExecCapableSSHHost
        let port: Int
        let cleanup: @MainActor () -> Void
        func dispose() { cleanup() }
    }

    private func makeFixture(
        roles: [(needle: String, role: ExecRole)] = []
    ) async throws -> Fixture {
        // Citadel's listener sets `SO_REUSEADDR`, so two fixtures starting at
        // once can end up "bound" to the same port without either bind failing,
        // and the retry inside `start` never triggers. The only reliable check
        // is to prove the port is ours by round-tripping a command against it.
        var lastError: (any Error)?
        for _ in 0..<4 {
            do {
                return try await makeFixtureOnce(roles: roles)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? CancellationError()
    }

    /// Roles must be declared here, before `start`, because the host snapshots
    /// its rules when it starts. A `label(...)` call made after `makeFixture()`
    /// returns has already missed its window, and the symptom is a silently
    /// mislabelled pid.
    private func makeFixtureOnce(roles: [(needle: String, role: ExecRole)] = []) async throws -> Fixture {
        let suite = "com.bonk.tests.deadline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let keyStore = TeamHostKeyStore(defaults: defaults)
        keyStore.injectSeed(Data(repeating: 0x7C, count: 32))
        let hostKey = try #require(keyStore.loadOrCreateHostKey())

        let host = ExecCapableSSHHost()
        // Before `start`, which snapshots the rules.
        for rule in roles { host.label(needle: rule.needle, as: rule.role) }
        guard await host.start(hostKey: hostKey, password: DeadlineFixtures.password,
                           ports: SSHFixturePort.deadline),
              let port = await host.port
        else { throw CancellationError() }

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: port,
            authenticationMethod: .passwordBased(username: "test", password: DeadlineFixtures.password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        let session = NativeSSHSession(
            client: client,
            endpoint: SSHEndpoint(host: "127.0.0.1", port: UInt16(port))
        )

        // Prove this port really belongs to our server before handing it over.
        // Uses a plain Citadel exec rather than the session's handle, so the
        // fixture's own liveness check cannot leave the handle latched and make
        // every later command in the test fail.
        //
        // ISOLATION SWITCH: set to false to measure whether a preceding exec
        // channel on the same connection is what stops the deadline's exec from
        // being terminated. Do not leave it off — the probe is what makes port
        // ownership verifiable.
        do {
            let probeBuffer = try await client.executeCommand("echo fixture-ready")
            guard String(buffer: probeBuffer).contains("fixture-ready") else {
                throw CancellationError()
            }
        } catch {
            nonisolated(unsafe) let doomed = client
            Task { try? await doomed.close() }
            host.stop()
            throw error
        }

        return Fixture(
            session: session,
            host: host,
            port: port,
            cleanup: {
                nonisolated(unsafe) let owned = client
                let h = host
                Task {
                    try? await owned.close()
                    h.stop()
                }
            }
        )
    }

    /// Wait for the process belonging to `role`, failing with `label` if none.
    private func waitForPID(
        _ role: ExecRole,
        label: String,
        on fixtureHost: ExecCapableSSHHost,
        timeout: Duration = .seconds(15)
    ) async throws -> Int32 {
        try await waitUntil(label: label, timeout: timeout) {
            fixtureHost.spawned.pid(for: role) != nil
        }
        // No force unwrap: if the wait did not establish the pid, the failure has
        // to name the role rather than trap the whole test host.
        guard let pid = fixtureHost.spawned.pid(for: role) else {
            Issue.record(Comment(rawValue: "\(label): no pid recorded for role \(role)"))
            throw CancellationError()
        }
        return pid
    }

    /// Poll until `condition` holds.
    ///
    /// `label` is mandatory and appears in the failure, because a bare
    /// "condition not met within 15.0 seconds" cannot say *which* wait failed.
    /// That ambiguity already cost a round here: three waits in one test, and
    /// the only available evidence identified none of them.
    private func waitUntil(
        label: String,
        timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record(Comment(rawValue: "\(label): condition not met within \(timeout)"))
    }
}

enum DeadlineFixtures {
    static let password = "deadline-fixture-password"
}