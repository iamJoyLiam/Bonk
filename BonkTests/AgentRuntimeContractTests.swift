//
//  AgentRuntimeContractTests.swift
//  BonkTests
//
//  Contract tests for P1.5 Agent Runtime Architecture:
//  - Decoupled AgentRuntime loop
//  - Immutable AgentEvent stream
//  - PermissionPolicy evaluation
//  - Instant hard cancellation through executionManager
//  - TranscriptStore auditing
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("P1.5 Agent Runtime Contract Tests")
struct AgentRuntimeContractTests {

    // MARK: - Mocks

    final class MockModelGateway: AgentModelGateway, @unchecked Sendable {
        private let responses: OSAllocatedUnfairLock<[LLMResponse]>

        init(responses: [LLMResponse]) {
            self.responses = OSAllocatedUnfairLock(uncheckedState: responses)
        }

        func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
            let next = responses.withLock { list -> LLMResponse? in
                guard !list.isEmpty else { return nil }
                return list.removeFirst()
            }
            return next ?? LLMResponse(text: "Mock default conclusion")
        }

        /// The double does not stream: the runtime falls back to a
        /// non-streaming turn, which is what these tests are about.
        func streamTurn(
            messages: [LLMMessage],
            tools: [LLMToolDefinition]
        ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
            nil
        }
    }

    final class MockExecutionHandle: CommandExecutionHandle, @unchecked Sendable {
        private let interrupted = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

        var wasInterrupted: Bool {
            interrupted.withLock { $0 }
        }

        func interrupt() async throws {
            interrupted.withLock { $0 = true }
        }

        func terminate() async throws {
            interrupted.withLock { $0 = true }
        }

        func close() async {}
    }

    // MARK: - Tests

    @Test("1. AgentRuntime emits events in correct order for direct synthesis")
    func testDirectSynthesisEventOrder() async {
        let gateway = MockModelGateway(responses: [
            LLMResponse(text: "Server load is normal.")
        ])
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )

        let stream = runtime.run(input: "How is the server?") { _, _ in
            ("ok", 0)
        }

        var collected: [AgentEvent] = []
        for await event in stream {
            collected.append(event)
        }

        #expect(collected.count == 3)
        #expect(collected[0] == .userMessage("How is the server?"))
        #expect(collected[1] == .assistantText("Server load is normal."))
        #expect(collected[2] == .completed)
    }

    @Test("2. AgentRuntime handles tool execution loop with permission allowed")
    func testToolExecutionLoop() async {
        let toolCall = LLMToolCall(
            id: "call-1",
            name: "run_command",
            argumentsJSON: "{\"command\":\"uptime\"}"
        )
        let gateway = MockModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [toolCall]),
            LLMResponse(text: "The server has been up for 24 days.")
        ])

        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )

        let stream = runtime.run(input: "Check server uptime") { cmd, register in
            #expect(cmd == "uptime")
            return ("up 24 days, 1 user", 0)
        }

        var collected: [AgentEvent] = []
        for await event in stream {
            collected.append(event)
        }

        #expect(collected.contains(.userMessage("Check server uptime")))
        #expect(collected.contains(where: {
            if case let .toolCallStarted(id, tool, _) = $0 {
                return id == "call-1" && tool == "run_command"
            }
            return false
        }))
        #expect(collected.contains(where: {
            if case let .toolOutput(id, output) = $0 {
                return id == "call-1" && output.contains("up 24 days")
            }
            return false
        }))
        #expect(collected.contains(where: {
            if case let .toolCompleted(id, exitCode, _) = $0 {
                return id == "call-1" && exitCode == 0
            }
            return false
        }))
        #expect(collected.contains(.assistantText("The server has been up for 24 days.")))
        #expect(collected.contains(.completed))
    }

    @Test("3. PermissionPolicy distinguishes safe, mutating, dangerous, and critical commands")
    func testPermissionPolicyModes() {
        let supervised = DefaultAgentPermissionPolicy(accessMode: .supervised)
        let readOnly = DefaultAgentPermissionPolicy(accessMode: .readOnly)
        let fullAccess = DefaultAgentPermissionPolicy(accessMode: .fullAccess)

        // Safe inspection (L1)
        #expect(supervised.evaluate(tool: "run_command", arguments: ["command": "ps aux"]) == .allowed)
        #expect(readOnly.evaluate(tool: "run_command", arguments: ["command": "ps aux"]) == .allowed)
        #expect(fullAccess.evaluate(tool: "run_command", arguments: ["command": "ps aux"]) == .allowed)

        // State mutation (L2)
        #expect(supervised.evaluate(tool: "run_command", arguments: ["command": "touch /tmp/foo"]) != .allowed)
        #expect(readOnly.evaluate(tool: "run_command", arguments: ["command": "touch /tmp/foo"]) == .blocked(reason: "Read-only mode blocks command modifying state: touch /tmp/foo"))
        #expect(fullAccess.evaluate(tool: "run_command", arguments: ["command": "touch /tmp/foo"]) == .allowed)

        // High risk (L3)
        #expect(supervised.evaluate(tool: "run_command", arguments: ["command": "rm -rf /var/cache"]) != .allowed)
        #expect(readOnly.evaluate(tool: "run_command", arguments: ["command": "rm -rf /var/cache"]) != .allowed)
        #expect(fullAccess.evaluate(tool: "run_command", arguments: ["command": "rm -rf /var/cache"]) != .allowed) // high-risk always confirms

        // Critical (L4)
        #expect(supervised.evaluate(tool: "run_command", arguments: ["command": ":(){ :|:& };:"]) == .blocked(reason: "Critical command blocked by security policy: :(){ :|:& };:"))
        #expect(readOnly.evaluate(tool: "run_command", arguments: ["command": ":(){ :|:& };:"]) == .blocked(reason: "Critical command blocked by security policy: :(){ :|:& };:"))
        #expect(fullAccess.evaluate(tool: "run_command", arguments: ["command": ":(){ :|:& };:"]) == .blocked(reason: "Critical command blocked by security policy: :(){ :|:& };:"))
    }

    /// Contract coverage only — **not** evidence that cancellation works.
    ///
    /// This was the test that hid Finding 3. The mock executor calls
    /// `register`, so the handle reaches the manager and the test goes green,
    /// while `NativeSSHSession` never registered anything and Stop was inert on
    /// every Secure Enclave host. A mock proves the escalation ladder runs; it
    /// cannot prove any transport ever hands it something to escalate.
    ///
    /// The production-path proof lives in `NativeSSHCancellationAuthorityTests`,
    /// which runs a real server, a real exec channel and a real subprocess.
    @Test("4. Hard cancellation halts active task and dispatches interrupt")
    func testAgentRuntimeHardCancellation() async throws {
        let mockHandle = MockExecutionHandle()
        let execManager = AgentExecutionManager()
        await execManager.registerActive(mockHandle)

        let toolCall = LLMToolCall(
            id: "call-hang",
            name: "run_command",
            argumentsJSON: "{\"command\":\"sleep 100\"}"
        )
        let gateway = MockModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [toolCall])
        ])

        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .fullAccess),
            executionManager: execManager
        )

        let hasStarted = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        let stream = runtime.run(input: "Run long command") { _, register in
            // Awaited registration: ordered before execution starts, so a
            // later cancel() is guaranteed to observe the handle. This is
            // the production invariant (see CommandHandleRegistration).
            await register?(mockHandle)
            hasStarted.withLock { $0 = true }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return ("done", 0)
        }

        let runTask = Task {
            for await _ in stream {}
        }

        // Wait until execution has registered the handle
        for _ in 0..<50 {
            if hasStarted.withLock({ $0 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Cancel runtime
        runtime.cancel()

        _ = await runTask.result
        // The interrupt is dispatched from a detached task, so it can land
        // after the run has already finished. Wait for it, bounded: the
        // assertion below is about whether the handle was interrupted, not
        // about how fast the interrupt arrived. Without the wait this test
        // fails about half the time under load, which makes it a coin flip
        // rather than a gate.
        for _ in 0..<50 {
            if mockHandle.wasInterrupted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(mockHandle.wasInterrupted)
    }

    @Test("An answer that arrives at once is not lost")
    func testAnswerGivenAtOnceIsNotLost() async {
        // The question is asked and answered in the same moment. If the
        // runtime puts the question on the wire before it can accept the
        // answer, the answer falls on the floor and the run waits
        // forever for an answer that already came and went.
        let toolCall = LLMToolCall(
            id: "call-needs-approval",
            name: "run_command",
            argumentsJSON: #"{"command":"touch /tmp/bonk-permission-contract"}"#
        )
        let gateway = MockModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [toolCall])
        ])
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )

        let finished = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        let runTask = Task {
            for await event in runtime.run(input: "touch it") { _, _ in ("ok", 0) } {
                if case let .permissionRequested(id, _, _, _) = event {
                    // The answer goes back the moment the question is
                    // seen — the tightest timing there is.
                    runtime.resolvePermission(id: id, approved: true)
                }
            }
            finished.withLock { $0 = true }
        }

        // Bounded: a gate that hangs is worse than one that fails.
        let deadline = Date().addingTimeInterval(10)
        while !finished.withLock({ $0 }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(
            finished.withLock { $0 },
            "the run must not wait forever for an answer that already arrived"
        )
        // Clean up: a run that is still waiting for an answer would
        // otherwise keep the test host alive after this test is over.
        runtime.cancel()
        runTask.cancel()
    }

    @Test("5. TranscriptStore records full audit history")
    func testTranscriptStoreRecordsEvents() {
        let store = AgentTranscriptStore()
        store.append(.userMessage("Check memory"))
        store.append(.toolCallStarted(id: "call-1", tool: "run_command", input: "free -m"))
        store.append(.toolOutput(id: "call-1", output: "Mem: 16000"))
        store.append(.toolCompleted(id: "call-1", exitCode: 0, duration: 0.12))
        store.append(.assistantText("Memory usage is healthy."))
        store.append(.completed)

        let transcript = store.exportTextTranscript()
        #expect(transcript.contains("[User]: Check memory"))
        #expect(transcript.contains("[ToolCall call-1]: run_command -> free -m"))
        #expect(transcript.contains("[ToolOutput call-1]: Mem: 16000"))
        #expect(transcript.contains("[Assistant]: Memory usage is healthy."))
        #expect(transcript.contains("[Completed]"))
    }

    @Test("6. Rejecting command permission immediately terminates loop without prompting model again")
    func testPermissionRejectionTerminatesLoopImmediately() async {
        let toolCall = LLMToolCall(
            id: "call-create",
            name: "run_command",
            argumentsJSON: "{\"command\":\"touch /tmp/data\"}"
        )
        let gateway = MockModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [toolCall]),
            LLMResponse(text: "Should NOT reach here")
        ])

        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )

        let stream = runtime.run(input: "Create data") { _, _ in
            ("ok", 0)
        }

        let task = Task {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
                if case let .permissionRequested(id, _, _, _) = event {
                    runtime.resolvePermission(id: id, approved: false)
                }
            }
            return events
        }

        let events = await task.value
        #expect(events.contains(where: {
            if case let .permissionResolved(id, approved) = $0 {
                return id == "call-create" && !approved
            }
            return false
        }))
        #expect(events.contains(where: {
            if case let .executionInterrupted(reason) = $0 {
                return reason.contains("取消") || reason.contains("rejected")
            }
            return false
        }))
        #expect(events.contains(.completed))
        #expect(!events.contains(.assistantText("Should NOT reach here")))
    }
}

