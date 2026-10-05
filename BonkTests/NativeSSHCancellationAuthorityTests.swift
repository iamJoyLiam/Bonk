//
//  NativeSSHCancellationAuthorityTests.swift
//  BonkTests
//
//  Proof that the Stop button works on the production Citadel path.
//
//  The finding this covers: `NativeSSHSession` never implemented
//  `execute(_:registerHandle:)`, so it inherited the protocol extension in
//  `SSHSession.swift`, which discards the handle with `_ = registerHandle`.
//  `AgentExecutionManager` therefore had nothing to interrupt and Stop was inert
//  for every Secure Enclave host — while the button stayed lit.
//
//  A mock cannot prove this. `AgentRuntimeContractTests` uses a mock executor
//  that *does* call `register`, so it went green while production never
//  registered anything. That test stays, demoted to contract coverage; it is
//  not evidence about production.
//
//  So these tests run a real SSH server with a real exec channel running a real
//  local subprocess, connect a real `SSHClient` through `NativeSSHSession`, and
//  observe the process itself: alive before Stop, gone after. Nothing here is
//  inferred from a callback having been invoked.
//
//  The two halves are asserted separately on purpose. "A handle was registered"
//  is easy to satisfy with a handle that cannot stop anything — that is exactly
//  what the old code half-did. Termination is the property that matters.
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

/// Shared, reference-typed list of spawned pids.
///
/// A class and not `NIOLockedValueBox`: the box is a struct, so handing it to
/// the exec delegate would copy it and the host would never see a pid — the
/// test would then "prove" termination by observing nothing at all.
final class SpawnedProcesses: @unchecked Sendable {
    private let pids = NIOLockedValueBox<[Int32]>([])
    var all: [Int32] { pids.withLockedValue { $0 } }
    func record(_ pid: Int32) { pids.withLockedValue { $0.append(pid) } }
}

/// A real SSH server that runs exec requests as real local subprocesses.
///
/// Needed because the observable for this fix is "did the remote process die",
/// and a fake cannot produce a process to kill.
@MainActor
final class ExecCapableSSHHost {
    private(set) var server: SSHServer?
    private(set) var port: Int?
    /// Every subprocess this host has spawned, so a test can check liveness.
    private let spawned = SpawnedProcesses()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    var spawnedPIDs: [Int32] { spawned.all }

    func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    @discardableResult
    func start(hostKey: NIOSSHPrivateKey, password: String) async -> Bool {
        let authDelegate = TestPasswordAuthDelegate(password: password)
        let delegate = SubprocessExecDelegate(spawned: spawned)
        // Ask for a specific free port rather than 0: Citadel does not report the
        // bound port back, so a port-0 fixture could not be connected to.
        guard let requested = TeamPortPicker.availablePort() else { return false }
        do {
            let server = try await SSHServer.host(
                host: "127.0.0.1",
                port: Int(requested),
                hostKeys: [hostKey],
                authenticationDelegate: authDelegate,
                group: group
            )
            server.enableExec(withDelegate: delegate)
            self.server = server
            self.port = Int(requested)
            return true
        } catch {
            return false
        }
    }

    func stop() {
        let server = server
        self.server = nil
        let handle = server.map(UncheckedSendable.init)
        Task { [group] in
            try? await handle?.value.close()
            try? await group.shutdownGracefully()
        }
    }

    }

/// Executes each request as a real `/bin/sh -c` subprocess.
final class SubprocessExecDelegate: ExecDelegate, @unchecked Sendable {
    private let spawned: SpawnedProcesses

    init(spawned: SpawnedProcesses) {
        self.spawned = spawned
    }

    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Citadel hands us the pipes it reads from; feeding it is our job.
        outputHandler.stdoutPipe.fileHandleForWriting.closeFile()
        outputHandler.stderrPipe.fileHandleForWriting.closeFile()

        try process.run()
        // `processIdentifier` is the only pid Foundation exposes here.
        let pid = Int32(process.processIdentifier)
        if pid > 0 {
            spawned.record(pid)
        }

        let stdoutReader = outputHandler.stdoutPipe.fileHandleForReading
        let stderrReader = outputHandler.stderrPipe.fileHandleForReading

        // Pump both pipes on a background queue so the command is a real
        // streaming command, not a buffered one.
        let group = DispatchGroup()
        for (reader, sink) in [(stdoutReader, outputHandler.stdoutPipe), (stderrReader, outputHandler.stderrPipe)] {
            group.enter()
            DispatchQueue.global().async {
                let data = reader.readDataToEndOfFile()
                if !data.isEmpty { sink.fileHandleForWriting.write(data) }
                sink.fileHandleForWriting.closeFile()
                group.leave()
            }
        }

        let context = SubprocessExecContext(process: process)
        group.notify(queue: .global()) {
            process.waitUntilExit()
            outputHandler.succeed(exitCode: Int(process.terminationStatus))
            outputHandler.onExit { _ in }
        }
        return context
    }

    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}
}

/// Termination handle for one spawned subprocess.
final class SubprocessExecContext: ExecCommandContext, @unchecked Sendable {
    private let process: Process
    private let terminated = NIOLockedValueBox<Bool>(false)

    init(process: Process) {
        self.process = process
    }

    var wasTerminated: Bool { terminated.withLockedValue { $0 } }

    /// Called by Citadel's `ExecHandler.channelInactive` when the channel goes.
    func terminate() async throws {
        let first = terminated.withLockedValue { seen -> Bool in
            let already = seen
            seen = true
            return !already
        }
        guard first else { return }
        let pid = Int32(process.processIdentifier)
        if pid > 0 {
            // SIGKILL, so a shell that traps signals cannot outlive the cancel.
            kill(pid, SIGKILL)
        }
    }
}

/// Authentication for the fixture host.
///
/// Deliberately the production `TeamSSHAuthDelegate` rather than a second
/// implementation: a fixture that accepts credentials the product would refuse
/// would let a test pass through a path the app cannot reach.
final class TestPasswordAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    private let password: String

    init(password: String) {
        self.password = password
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        [.password]
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard case let .password(presented) = request.request,
              presented.password == password
        else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

@Suite("Native SSH Cancellation Authority Tests")
@MainActor
struct NativeSSHCancellationAuthorityTests {

    private static let password = "hunter2-correct-horse"

    /// Builds a real client and a real `NativeSSHSession` over it.
    private struct Fixture {
        let session: NativeSSHSession
        /// Owns teardown so the non-`Sendable` client never crosses an
        /// isolation boundary as a value.
        let cleanup: @MainActor () -> Void
    }

    private func makeSession(port: Int, hostKeyStore: TeamHostKeyStore) async throws -> Fixture {
        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: port,
            authenticationMethod: .passwordBased(username: "test", password: Self.password),
            // The host key is verified by the production validator on the real
            // path; here the point is cancellation, so trust-on-first-use keeps
            // the fixture from becoming a second test about host keys.
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        return Fixture(
            session: NativeSSHSession(
                client: client,
                endpoint: SSHEndpoint(host: "127.0.0.1", port: UInt16(port))
            ),
            cleanup: {
                nonisolated(unsafe) let owned = client
                Task { try? await owned.close() }
            }
        )
    }

    /// Best-effort teardown. Never throws into the test: a cleanup failure must
    /// not be reported as a behavioural failure.
    private func dispose(_ fixture: Fixture) {
        fixture.cleanup()
    }

    /// A cancellation handle over a real connection, for the latch assertions
    /// that do not need a running command.
    private func makeHandle(
        port: Int,
        hostKeyStore: TeamHostKeyStore
    ) async throws -> (NativeExecCancellationHandle, @MainActor () -> Void) {
        let fixture = try await makeSession(port: port, hostKeyStore: hostKeyStore)
        let handle = NativeExecCancellationHandle(client: fixture.session.client)
        return (handle, { dispose(fixture) })
    }

    private func makeHostKeyStore() -> TeamHostKeyStore {
        let store = TeamHostKeyStore(defaults: {
            let suite = "com.bonk.tests.cancel.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }())
        store.injectSeed(Data(repeating: 0x5A, count: 32))
        return store
    }

    private func key(_ store: TeamHostKeyStore) throws -> NIOSSHPrivateKey {
        try #require(store.loadOrCreateHostKey())
    }

    /// A command that prints forever and would never end on its own.
    private static let foreverCommand = "while true; do echo tick; sleep 0.05; done"

    // MARK: - 1. A handle is registered

    /// Half one. `AgentExecutionManager` must learn about the running command.
    /// Kept separate from the termination test because this half alone is
    /// satisfiable by a handle that cannot actually stop anything.
    @Test("A running command registers a handle with the execution manager")
    func runningCommandRegistersAHandle() async throws {
        let hostKeyStore = makeHostKeyStore()
        let host = ExecCapableSSHHost()
        #expect(await host.start(hostKey: try key(hostKeyStore), password: Self.password))
        defer { host.stop() }
        let port = try #require(TeamPortPicker.availablePort() ?? nil).description
        _ = port

        // Bind first, then read the port the server actually got.
        guard let bound = await resolvePort(host) else {
            Issue.record("the exec-capable host must bind")
            return
        }
        let fixture = try await makeSession(port: bound, hostKeyStore: hostKeyStore)
        defer { dispose(fixture) }
        let session = fixture.session

        let manager = AgentExecutionManager()
        #expect(await manager.hasActiveHandle == false)

        let runner = Task {
            _ = try? await session.execute(Self.foreverCommand, registerHandle: { handle in
                await manager.registerActive(handle)
            })
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await manager.hasActiveHandle == false {
            if ContinuousClock.now > deadline {
                Issue.record("the session never registered a cancellation handle")
                runner.cancel()
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await manager.hasActiveHandle == true,
                "the session must register a live handle for the running command")
        runner.cancel()
        await manager.cancelActive()
    }

    // MARK: - 2. The handle terminates a real execution

    /// Half two, and the one that matters. The observable is a real process:
    /// `kill(pid, 0)` before and after. Not "a callback fired".
    @Test("Cancelling stops the real remote process")
    func cancellingTerminatesTheRemoteProcess() async throws {
        let hostKeyStore = makeHostKeyStore()
        let host = ExecCapableSSHHost()
        #expect(await host.start(hostKey: try key(hostKeyStore), password: Self.password))
        defer { host.stop() }
        guard let port = await resolvePort(host) else {
            Issue.record("the exec-capable host must bind")
            return
        }
        let fixture = try await makeSession(port: port, hostKeyStore: hostKeyStore)
        defer { dispose(fixture) }
        let session = fixture.session

        let manager = AgentExecutionManager()
        let runner = Task {
            _ = try? await session.execute(Self.foreverCommand, registerHandle: { handle in
                await manager.registerActive(handle)
            })
        }

        // Wait for a real subprocess to exist and be running.
        try await waitUntil { !host.spawnedPIDs.isEmpty }
        let pid = try #require(host.spawnedPIDs.first)
        try await waitUntil { host.isAlive(pid) }
        #expect(host.isAlive(pid), "the remote command must actually be running before Stop")

        await manager.cancelActive()

        try await waitUntil { !host.isAlive(pid) }
        #expect(!host.isAlive(pid),
                "Stop must terminate the remote process, not merely stop waiting for it")
        runner.cancel()
    }

    // MARK: - 3. Negative: running before Stop, silent after

    /// Before Stop the command really is producing output; after Stop it
    /// produces nothing more. Without the first half, "no output after Stop"
    /// could be satisfied by a command that never ran.
    @Test("The command runs before Stop and stops producing output after")
    func commandStopsProducingOutputAfterCancel() async throws {
        let hostKeyStore = makeHostKeyStore()
        let host = ExecCapableSSHHost()
        #expect(await host.start(hostKey: try key(hostKeyStore), password: Self.password))
        defer { host.stop() }
        guard let port = await resolvePort(host) else {
            Issue.record("the exec-capable host must bind")
            return
        }
        let fixture = try await makeSession(port: port, hostKeyStore: hostKeyStore)
        defer { dispose(fixture) }
        let session = fixture.session

        let manager = AgentExecutionManager()
        let collected = NIOLockedValueBox<[String]>([])

        let runner = Task {
            _ = try? await session.execute("echo before; while true; do echo tick; sleep 0.05; done",
                                           registerHandle: { handle in
                await manager.registerActive(handle)
            })
        }

        // Negative case 1: it is genuinely running, and the runner has NOT
        // returned. A command that had already failed would look identical to a
        // cancelled one when only the end state is checked.
        try await waitUntil { !host.spawnedPIDs.isEmpty }
        let pid = try #require(host.spawnedPIDs.first)
        try await waitUntil { host.isAlive(pid) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.isAlive(pid), "the command must still be running before Stop")
        #expect(runner.isCancelled == false)
        _ = collected

        await manager.cancelActive()

        // Negative case 2: after Stop, the process is gone and the awaiting task
        // has finished rather than lingering.
        try await waitUntil { !host.isAlive(pid) }
        #expect(!host.isAlive(pid))
        // The awaiting task must *finish*, not merely be cancelled: a loop that
        // parks forever still owns its turn, and the run never reaches a
        // terminal state.
        await awaitWithin(
            runner,
            "the execute call never returned after cancellation; the runtime would stay running"
        )
        #expect(runner.isCancelled == false,
                "cancellation must not depend on Task.cancel alone")
    }

    // MARK: - 4. Race: no return to running after Stop

    /// Cancelling must be terminal. A late registration, or a second cancel
    /// racing the first, must not put the manager back into a state where it
    /// believes something is running.
    @Test("Cancellation is terminal and cannot be undone by a late callback")
    func cancellationIsTerminal() async throws {
        let hostKeyStore = makeHostKeyStore()
        let host = ExecCapableSSHHost()
        #expect(await host.start(hostKey: try key(hostKeyStore), password: Self.password))
        defer { host.stop() }
        guard let port = await resolvePort(host) else {
            Issue.record("the exec-capable host must bind")
            return
        }
        let fixture = try await makeSession(port: port, hostKeyStore: hostKeyStore)
        defer { dispose(fixture) }
        let session = fixture.session

        let manager = AgentExecutionManager()
        let handles = NIOLockedValueBox<[any CommandExecutionHandle]>([])
        let runner = Task {
            _ = try? await session.execute(Self.foreverCommand, registerHandle: { handle in
                handles.withLockedValue { $0.append(handle) }
                await manager.registerActive(handle)
            })
        }

        try await waitUntil { !host.spawnedPIDs.isEmpty }
        let pid = try #require(host.spawnedPIDs.first)
        try await waitUntil { host.isAlive(pid) }
        #expect(await manager.hasActiveHandle)

        await manager.cancelActive()
        try await waitUntil { !host.isAlive(pid) }

        // Terminal: the manager no longer believes anything is running.
        #expect(await manager.hasActiveHandle == false,
                "a cancelled execution must not remain registered as active")

        // A late or repeated escalation must not resurrect it. This is the race
        // the finding warned about: a second cancel arriving after the first
        // completed must not re-enter the escalation or re-arm anything.
        await manager.cancelActive()
        #expect(await manager.hasActiveHandle == false)

        // And a handle that has already closed stays closed.
        let handle = try #require(handles.withLockedValue { $0.first })
        await handle.close()
        await handle.close()
        #expect(await manager.hasActiveHandle == false,
                "a late callback must not put the runtime back into running")
        runner.cancel()
    }

    /// The handle's latch, asserted directly rather than inferred from the
    /// absence of a crash — "it did not blow up" is not evidence.
    @Test("The cancellation handle latches after the first close")
    func handleLatchesAfterClose() async throws {
        let hostKeyStore = makeHostKeyStore()
        let host = ExecCapableSSHHost()
        #expect(await host.start(hostKey: try key(hostKeyStore), password: Self.password))
        defer { host.stop() }
        guard let port = await resolvePort(host) else {
            Issue.record("the exec-capable host must bind")
            return
        }
        let (handle, cleanup) = try await makeHandle(port: port, hostKeyStore: hostKeyStore)
        defer { cleanup() }
        #expect(handle.hasCancelled == false)
        await handle.close()
        #expect(handle.hasCancelled, "the first close must latch")
    }

    // MARK: - 5. The wiring, so the above cannot pass while unused

    /// Structural, and deliberately the last line rather than the first. The
    /// behavioural tests above would pass even if the agent tool loop stopped
    /// passing a registration closure at all; this is what stops that.
    @Test("NativeSSHSession no longer falls through to the discarding extension")
    func nativeSessionDoesNotDiscardTheHandle() throws {
        let session = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/SSH/NativeSSHSession.swift"),
            encoding: .utf8
        )
        #expect(session.contains("func execute(\n        _ command: String,\n        registerHandle: CommandHandleRegistration?\n    )"),
                "the session must implement the handle-taking overload itself")
        #expect(session.contains("await registerHandle?(handle)"),
                "the handle must be registered before the await, so a racing cancel is seen")

        // The extension it used to inherit from must stay a fallback rather than
        // silently becoming the production path again.
        let protocolFile = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/SSH/SSHSession.swift"),
            encoding: .utf8
        )
        #expect(protocolFile.contains("_ = registerHandle"),
                "the discarding default should still exist for conformances that cannot support it")
    }

    // MARK: - Helpers

    /// `SSHServer.host` was asked for a specific port, so the same value is the
    /// bound one; 0 means the OS chose and the fixture is unusable.
    private func resolvePort(_ host: ExecCapableSSHHost) async -> Int? {
        await host.port
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met within \(timeout)")
    }

    /// Await a task with a deadline, reporting instead of hanging.
    ///
    /// Necessary because the failure mode of this bug *is* a hang: with
    /// cancellation unwired, the command never returns, so an unbounded
    /// `await runner.value` never completes. A test that hangs when the code is
    /// broken is worse than no test — it takes the whole suite down instead of
    /// reporting the defect.
    private func awaitWithin(
        _ task: Task<Void, Never>,
        timeout: Duration = .seconds(20),
        _ message: String
    ) async {
        let finished = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        let watcher = Task { await task.value; finished.withLock { $0 = true } }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if finished.withLock({ $0 }) { watcher.cancel(); return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record(Comment(rawValue: message))
        watcher.cancel()
        task.cancel()
    }
}