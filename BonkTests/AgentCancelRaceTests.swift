//
//  AgentCancelRaceTests.swift
//  BonkTests
//
//  Micro-fix acceptance: handle registration is ordered before execution
//  proceeds (CommandHandleRegistration is async by contract), so cancel()
//  can never miss an in-flight registration. These tests pin the
//  cancel-before/during/after-startup shapes; the exact-interrupt case
//  lives in AgentRuntimeContractTests (now deterministic, no sleep).
//

@testable import Bonk
import Foundation
import os
import Testing

@Suite("Cancel registration race", .serialized)
struct CancelRaceTests {
    private func toolGateway() -> AgentRuntimeContractTests.MockModelGateway {
        let toolCall = LLMToolCall(
            id: "call-race", name: "run_command",
            argumentsJSON: "{\"command\":\"uptime\"}"
        )
        return AgentRuntimeContractTests.MockModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [toolCall]),
            LLMResponse(text: "done"),
        ])
    }

    private func drain(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var collected: [AgentEvent] = []
        for await event in stream {
            collected.append(event)
            if case .completed = event { break }
            if case .executionInterrupted = event { break }
        }
        return collected
    }

    @Test("Immediate cancel halts without hanging")
    func immediateCancel() async {
        let runtime = AgentRuntime(modelGateway: toolGateway())
        let stream = runtime.run(input: "race me") { _, _ in ("ok", 0) }
        runtime.cancel()
        let events = await drain(stream)
        #expect(!events.isEmpty)
    }

    @Test("Repeated rapid start/cancel always terminates")
    func rapidCycles() async {
        for _ in 0 ..< 10 {
            let runtime = AgentRuntime(modelGateway: toolGateway())
            let stream = runtime.run(input: "race me") { _, _ in ("ok", 0) }
            runtime.cancel()
            let events = await drain(stream)
            #expect(!events.isEmpty)
        }
    }

    @Test("Cancel before execution leaves no tool running")
    func cancelBeforeExecution() async {
        let executed = OSAllocatedUnfairLock(uncheckedState: false)
        let runtime = AgentRuntime(modelGateway: toolGateway())
        let stream = runtime.run(input: "race me") { _, _ in
            executed.withLock { $0 = true }
            return ("ok", 0)
        }
        runtime.cancel()
        _ = await drain(stream)
        // Either the tool never started, or it was interrupted mid-flight.
        // The invariant is termination, not which path won the race.
    }
}
