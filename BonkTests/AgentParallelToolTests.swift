//
//  AgentParallelToolTests.swift
//  BonkTests
//
//  Parallel tool execution.
//
//  The model can ask for several things in one turn. Running them one
//  after another makes the user wait for three round trips instead of
//  one. But two things that happen at the same time can interfere, so
//  not every call may share a batch.
//
//  What has to hold:
//
//  1. **Only reads share a batch.** A call that changes something, or
//     that needs the user's answer, runs alone.
//
//  2. **They really do run at the same time.** A gate that only checks
//     the plan proves nothing; the gate has to observe two commands in
//     flight together.
//
//  3. **The model sees the order it asked for.** The results go back in
//     the model's order, not in the order the commands happened to
//     finish.
//
//  4. **One question at a time.** Two commands that need approval must
//     not put two dialogs on the screen.
//
//  5. **Cancelling stops everything.** With commands in flight, the stop
//     button has to reach all of them, not just the last one registered.
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("Parallel tool execution")
struct AgentParallelToolTests {

    // MARK: - The plan (pure)

    @Test("Consecutive reads run together")
    func consecutiveReadsRunTogether() {
        let batches = ToolCallPlanner.batches(for: [
            Self.call("1", ReadFileTool.toolName, #"{"path":"/tmp/a"}"#),
            Self.call("2", ReadFileTool.toolName, #"{"path":"/tmp/b"}"#)
        ])
        #expect(batches.count == 1)
        #expect(batches.first?.isParallel == true)
        #expect(batches.first?.calls.count == 2)
    }

    @Test("A command that changes something runs alone")
    func aMutatingCommandRunsAlone() {
        let batches = ToolCallPlanner.batches(for: [
            Self.call("1", ReadFileTool.toolName, #"{"path":"/tmp/a"}"#),
            Self.call("2", BashRunTool.toolName, #"{"command":"touch /tmp/x"}"#),
            Self.call("3", ReadFileTool.toolName, #"{"path":"/tmp/b"}"#)
        ])
        #expect(batches.count == 3)
        #expect(batches[0].isParallel == true)
        #expect(batches[1].isParallel == false, "a mutating command must not share a batch")
        #expect(batches[2].isParallel == true)
    }

    @Test("A command that only inspects can share a batch")
    func aReadOnlyCommandJoinsTheBatch() {
        let batches = ToolCallPlanner.batches(for: [
            Self.call("1", ReadFileTool.toolName, #"{"path":"/tmp/a"}"#),
            Self.call("2", BashRunTool.toolName, #"{"command":"df -h"}"#)
        ])
        #expect(batches.count == 1)
        #expect(batches.first?.isParallel == true)
    }

    @Test("A command that is risky enough to ask about runs alone")
    func aRiskyCommandRunsAlone() {
        let batches = ToolCallPlanner.batches(for: [
            Self.call("1", ReadFileTool.toolName, #"{"path":"/tmp/a"}"#),
            Self.call("2", BashRunTool.toolName, #"{"command":"rm -rf /tmp/x"}"#)
        ])
        #expect(batches.count == 2)
        #expect(batches[1].isParallel == false)
    }

    @Test("A tool nobody classified is not safe to overlap")
    func anUnknownToolIsNotSafe() {
        let batches = ToolCallPlanner.batches(for: [
            Self.call("1", "some_future_tool", #"{"whatever":"x"}"#)
        ])
        #expect(batches.first?.isParallel == false)
    }

    @Test("A call whose arguments do not parse is not safe to overlap")
    func anUnparseableCallIsNotSafe() {
        let batches = ToolCallPlanner.batches(for: [
            Self.call("1", BashRunTool.toolName, "not json at all")
        ])
        #expect(batches.first?.isParallel == false)
    }

    @Test("The order the model asked for is kept")
    func theOrderIsKept() {
        let batches = ToolCallPlanner.batches(for: [
            Self.call("1", ReadFileTool.toolName, #"{"path":"/tmp/a"}"#),
            Self.call("2", ReadFileTool.toolName, #"{"path":"/tmp/b"}"#),
            Self.call("3", ReadFileTool.toolName, #"{"path":"/tmp/c"}"#)
        ])
        let ids = batches.flatMap { $0.calls }.map(\.id)
        #expect(ids == ["1", "2", "3"])
    }

    @Test("A batch bigger than the host can carry is split")
    func aBigBatchIsSplit() {
        let calls = (1...20).map {
            Self.call("\($0)", ReadFileTool.toolName, #"{"path":"/tmp/\($0)"}"#)
        }
        let batches = ToolCallPlanner.batches(for: calls)
        #expect(batches.count == 3)
        #expect(batches.allSatisfy { $0.calls.count <= ToolCallPlanner.maxParallelCalls })
        #expect(
            batches.flatMap { $0.calls }.map(\.id) == (1...20).map { "\($0)" },
            "splitting a batch must not change the order"
        )
    }

    // MARK: - The runtime

    /// A barrier that only lets go when every expected caller has arrived.
    ///
    /// The wait is bounded: a gate that hangs is worse than one that
    /// fails. The caller learns whether the others arrived, so a
    /// sequential run reports itself instead of hanging.
    final class ArrivalBarrier: @unchecked Sendable {
        private let arrived = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        private let expected: Int
        private let deadline: Date

        init(expected: Int, timeout: TimeInterval = 3) {
            self.expected = expected
            self.deadline = Date().addingTimeInterval(timeout)
        }

        /// Wait for the others. Returns whether they arrived.
        @discardableResult
        func wait() async -> Bool {
            arrived.withLock { $0 += 1 }
            while Date() < deadline {
                if arrived.withLock({ $0 }) >= expected { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return arrived.withLock({ $0 }) >= expected
        }
    }

    /// A gateway that asks for two reads on its first turn.
    final class TwoReadGateway: AgentModelGateway, @unchecked Sendable {
        private let turn = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        private let requests = OSAllocatedUnfairLock<[[LLMMessage]]>(uncheckedState: [])
        var captured: [[LLMMessage]] { requests.withLock { $0 } }

        func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
            requests.withLock { $0.append(messages) }
            let index = turn.withLock { current -> Int in
                defer { current += 1 }
                return current
            }
            guard index == 0 else { return LLMResponse(text: "All done.") }
            return LLMResponse(text: "", toolCalls: [
                AgentParallelToolTests.call("call-a", ReadFileTool.toolName, #"{"path":"/tmp/a"}"#),
                AgentParallelToolTests.call("call-b", ReadFileTool.toolName, #"{"path":"/tmp/b"}"#)
            ])
        }

        func streamTurn(
            messages: [LLMMessage],
            tools: [LLMToolDefinition]
        ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
            nil
        }
    }

    /// A gateway that asks for two commands that both need approval.
    final class TwoMutatingGateway: AgentModelGateway, @unchecked Sendable {
        private let turn = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        private let requests = OSAllocatedUnfairLock<[[LLMMessage]]>(uncheckedState: [])
        var captured: [[LLMMessage]] { requests.withLock { $0 } }

        func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
            requests.withLock { $0.append(messages) }
            let index = turn.withLock { current -> Int in
                defer { current += 1 }
                return current
            }
            guard index == 0 else { return LLMResponse(text: "All done.") }
            return LLMResponse(text: "", toolCalls: [
                AgentParallelToolTests.call("call-a", BashRunTool.toolName, #"{"command":"touch /tmp/a"}"#),
                AgentParallelToolTests.call("call-b", BashRunTool.toolName, #"{"command":"touch /tmp/b"}"#)
            ])
        }

        func streamTurn(
            messages: [LLMMessage],
            tools: [LLMToolDefinition]
        ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
            nil
        }
    }

    private static func call(_ id: String, _ name: String, _ arguments: String) -> LLMToolCall {
        LLMToolCall(id: id, name: name, argumentsJSON: arguments)
    }

    @Test("Two independent reads run at the same time")
    func twoReadsRunAtTheSameTime() async {
        let gateway = TwoReadGateway()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        // Each command waits for the other to arrive. If they ran one
        // after the other, the first one would wait alone and time out —
        // and say so.
        let barrier = ArrivalBarrier(expected: 2)
        for await event in runtime.run(input: "read both") { _, _ in
            let together = await barrier.wait()
            return (together ? "concurrent" : "alone", 0)
        } {
            if case let .permissionRequested(id, _, _, _) = event {
                runtime.resolvePermission(id: id, approved: true)
            }
        }

        let toolMessages = (gateway.captured.last ?? []).filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        #expect(
            toolMessages.allSatisfy { $0.content.contains("concurrent") },
            "both reads must have been in flight together, not one after the other"
        )
    }

    @Test("The model sees the results in the order it asked for")
    func theResultsKeepTheModelsOrder() async {
        let gateway = TwoReadGateway()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        // The first call is the slower one, so the order they finish in
        // is the opposite of the order the model asked for. The results
        // must still go back in the model's order.
        for await event in runtime.run(input: "read both") { command, _ in
            if command.contains("/tmp/a") {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return (command.contains("/tmp/a") ? "output-a" : "output-b", 0)
        } {
            if case let .permissionRequested(id, _, _, _) = event {
                runtime.resolvePermission(id: id, approved: true)
            }
        }

        let toolMessages = (gateway.captured.last ?? []).filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        let firstIndex = toolMessages.firstIndex { $0.content.contains("output-a") }
        let secondIndex = toolMessages.firstIndex { $0.content.contains("output-b") }
        #expect(firstIndex != nil)
        #expect(secondIndex != nil)
        #expect(
            firstIndex != nil && secondIndex != nil && firstIndex! < secondIndex!,
            "the results must be in the order the model asked for, not the order they finished"
        )
    }

    @Test("Two commands that need approval ask one at a time")
    func twoApprovalsAreNotAskedAtOnce() async {
        let gateway = TwoMutatingGateway()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        let events = OSAllocatedUnfairLock<[String]>(uncheckedState: [])
        let finished = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        let runTask = Task {
            for await event in runtime.run(input: "touch both") { _, _ in ("ok", 0) } {
                switch event {
                case let .permissionRequested(id, _, _, _):
                    events.withLock { $0.append("requested") }
                    runtime.resolvePermission(id: id, approved: true)
                case .permissionResolved:
                    events.withLock { $0.append("resolved") }
                default:
                    break
                }
            }
            finished.withLock { $0 = true }
        }

        // Bounded: a gate that hangs is worse than one that fails.
        let deadline = Date().addingTimeInterval(15)
        while !finished.withLock({ $0 }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(finished.withLock { $0 }, "the run must finish")

        #expect(
            events.withLock { $0 } == ["requested", "resolved", "requested", "resolved"],
            "the second question must not be asked before the first is answered"
        )
        runtime.cancel()
        runTask.cancel()
    }

    // MARK: - Cancelling

    /// A handle that records whether it was interrupted.
    final class RecordingHandle: CommandExecutionHandle, @unchecked Sendable {
        private let interrupted = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        var wasInterrupted: Bool { interrupted.withLock { $0 } }

        func interrupt() async throws { interrupted.withLock { $0 = true } }
        func terminate() async throws { interrupted.withLock { $0 = true } }
        func close() async {}
    }

    @Test("Cancelling stops every command that is running")
    func cancellingStopsEveryCommand() async {
        let manager = AgentExecutionManager()
        let first = RecordingHandle()
        let second = RecordingHandle()
        await manager.registerActive(first)
        await manager.registerActive(second)
        #expect(await manager.activeHandleCount == 2)

        await manager.cancelActive()

        #expect(first.wasInterrupted, "the first command must be stopped too")
        #expect(second.wasInterrupted)
    }

    // MARK: - The transcript

    @Test("A call's output lands on its own message")
    func theOutputLandsOnItsOwnMessage() {
        let first = AgentMessage(role: .commandOutput, content: "", command: "a", status: .running)
        let second = AgentMessage(role: .commandOutput, content: "", command: "b", status: .running)
        let map = ["call-a": first.id, "call-b": second.id]
        let messages = [first, second]

        let index = AgentEngine.indexOfMessage("call-b", in: map, messages: messages)
        #expect(index == 1, "the output must land on the call that produced it")
        #expect(AgentEngine.indexOfMessage("call-unknown", in: map, messages: messages) == nil)
    }

    // MARK: - The permission question

    @Test("The answer channel is open before the question is asked")
    func theAnswerChannelOpensFirst() throws {
        // A black-box test cannot catch this one: the window between
        // "the question is on the wire" and "the answer can be received"
        // is a couple of instructions wide, so an answer sent the moment
        // the question appears always arrives after the channel is open.
        //
        // What can be checked is the shape that makes the window
        // impossible: the channel is opened first, and the question goes
        // out second. Reading the source is the only way to see it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Bonk/Services/Agent/Runtime/AgentRuntime.swift"),
            encoding: .utf8
        )
        guard let store = source.range(of: "pendingApprovals.withLock { $0[callId] = cont }"),
              let ask = source.range(of: "emit(.permissionRequested(")
        else {
            Issue.record("the permission question was not found in the runtime")
            return
        }
        #expect(
            store.lowerBound < ask.lowerBound,
            "the answer channel must be open before the question is asked, or an answer can be lost"
        )
    }
}
