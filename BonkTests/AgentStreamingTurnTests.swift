//
//  AgentStreamingTurnTests.swift
//  BonkTests
//
//  The agent loop, streaming.
//
//  The defect: `AgentModelGateway.stream` existed and had no production
//  caller. The agent loop asked for a whole turn with `chat`, so the user
//  saw nothing until the turn was over.
//
//  A streaming turn is not a streaming answer. The model writes its text as
//  it goes *and* asks for commands to run, and both halves arrive
//  interleaved — so a parser that only understood text would lose the tool
//  calls, and with them the whole agent loop.
//
//  These tests cover the two wire formats' accumulators (pure), and the
//  runtime's behaviour when the provider can stream and when it cannot.
//

import Foundation
import os
import Testing
@testable import Bonk

// MARK: - The OpenAI-compatible accumulator

@Suite("OpenAI stream accumulator")
struct OpenAIStreamAccumulatorTests {

    @Test("Text arrives in pieces and is reported as it arrives")
    func textIsReportedAsItArrives() {
        var accumulator = OpenAIStreamAccumulator()
        let events = accumulator.ingest(#"{"choices":[{"delta":{"content":"Hello"}}]}"#)
        #expect(events == [.textDelta("Hello")])
        #expect(accumulator.text == "Hello")

        let more = accumulator.ingest(#"{"choices":[{"delta":{"content":" world"}}]}"#)
        #expect(more == [.textDelta(" world")])
        #expect(accumulator.text == "Hello world")
    }

    @Test("A tool call is assembled from its fragments")
    func toolCallIsAssembled() {
        var accumulator = OpenAIStreamAccumulator()
        _ = accumulator.ingest("""
        {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"run_command","arguments":""}}]}}]}
        """)
        _ = accumulator.ingest("""
        {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\""}}]}}]}
        """)
        _ = accumulator.ingest("""
        {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"ls\\"}"}}]}}]}
        """)

        let calls = accumulator.toolCalls
        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_1")
        #expect(calls.first?.name == "run_command")
        #expect(calls.first?.argumentsJSON == #"{"command":"ls"}"#)
    }

    @Test("Several tool calls keep their order")
    func severalToolCallsKeepTheirOrder() {
        var accumulator = OpenAIStreamAccumulator()
        _ = accumulator.ingest("""
        {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"second","arguments":"{}"}}]}}]}
        """)
        _ = accumulator.ingest("""
        {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"first","arguments":"{}"}}]}}]}
        """)

        let calls = accumulator.toolCalls
        #expect(calls.count == 2)
        // Ordered by the model's own index, not by arrival order.
        #expect(calls.first?.name == "first")
        #expect(calls.last?.name == "second")
    }

    @Test("Reasoning is reported separately from the answer")
    func reasoningIsSeparate() {
        var accumulator = OpenAIStreamAccumulator()
        let events = accumulator.ingest("""
        {"choices":[{"delta":{"reasoning_content":"thinking..."}}]}
        """)
        #expect(events == [.reasoning("thinking...")])
        #expect(accumulator.text.isEmpty)
    }

    @Test("Usage is read from the reported chunk")
    func usageIsRead() {
        var accumulator = OpenAIStreamAccumulator()
        _ = accumulator.ingest(#"{"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#)
        #expect(accumulator.usage?.inputTokens == 10)
        #expect(accumulator.usage?.outputTokens == 5)
    }

    @Test("A payload Bonk does not understand is ignored, not fatal")
    func unknownPayloadsAreIgnored() {
        var accumulator = OpenAIStreamAccumulator()
        #expect(accumulator.ingest("[DONE]").isEmpty)
        #expect(accumulator.ingest("not json at all").isEmpty)
        #expect(accumulator.ingest("").isEmpty)
        #expect(accumulator.ingest(#"{"choices":[]}"#).isEmpty)
        #expect(accumulator.text.isEmpty)
    }

    @Test("A fragment with no name is not a tool call")
    func namelessFragmentsAreNotToolCalls() {
        var accumulator = OpenAIStreamAccumulator()
        _ = accumulator.ingest("""
        {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}
        """)
        #expect(accumulator.toolCalls.isEmpty,
                "a call with no name cannot be run")
    }
}

// MARK: - The Anthropic accumulator

@Suite("Anthropic stream accumulator")
struct AnthropicStreamAccumulatorTests {

    @Test("Text arrives in pieces")
    func textArrivesInPieces() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.ingest(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        let events = accumulator.ingest(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#)
        #expect(events == [.textDelta("Hello")])
        #expect(accumulator.text == "Hello")
    }

    @Test("A tool call is assembled from its input fragments")
    func toolCallIsAssembled() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.ingest("""
        {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_command","input":{}}}
        """)
        _ = accumulator.ingest("""
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\""}}
        """)
        _ = accumulator.ingest("""
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":":\\"ls\\"}"}}
        """)

        let calls = accumulator.toolCalls
        #expect(calls.count == 1)
        #expect(calls.first?.id == "toolu_1")
        #expect(calls.first?.name == "run_command")
        #expect(calls.first?.argumentsJSON == #"{"command":"ls"}"#)
    }

    @Test("Usage comes from the message start and the message delta")
    func usageIsRead() {
        var accumulator = AnthropicStreamAccumulator()
        _ = accumulator.ingest(#"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}"#)
        #expect(accumulator.usage?.inputTokens == 10)
        _ = accumulator.ingest(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}"#)
        #expect(accumulator.usage?.outputTokens == 15)
    }

    @Test("Thinking is reported separately from the answer")
    func thinkingIsSeparate() {
        var accumulator = AnthropicStreamAccumulator()
        let events = accumulator.ingest(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#)
        #expect(events == [.reasoning("hmm")])
        #expect(accumulator.text.isEmpty)
    }

    @Test("A payload Bonk does not understand is ignored, not fatal")
    func unknownPayloadsAreIgnored() {
        var accumulator = AnthropicStreamAccumulator()
        #expect(accumulator.ingest("").isEmpty)
        #expect(accumulator.ingest("not json").isEmpty)
        #expect(accumulator.ingest(#"{"type":"something_new"}"#).isEmpty)
    }
}

// MARK: - The runtime

/// A gateway that streams a turn: one script per turn.
final class ScriptedStreamingGateway: AgentModelGateway, @unchecked Sendable {
    private let scripts: [[LLMStreamEvent]]
    private let turn = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
    private let requests = OSAllocatedUnfairLock<[[LLMMessage]]>(uncheckedState: [])

    var captured: [[LLMMessage]] { requests.withLock { $0 } }

    init(scripts: [[LLMStreamEvent]]) {
        self.scripts = scripts
    }

    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
        requests.withLock { $0.append(messages) }
        return LLMResponse(text: "not streamed")
    }

    func streamTurn(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
        requests.withLock { $0.append(messages) }
        let index = turn.withLock { current -> Int in
            defer { current += 1 }
            return current
        }
        let script = scripts.indices.contains(index) ? scripts[index] : []
        return AsyncThrowingStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.yield(.completed)
            continuation.finish()
        }
    }
}

/// A gateway that cannot stream: the runtime must fall back.
final class NonStreamingGateway: AgentModelGateway, @unchecked Sendable {
    private let requests = OSAllocatedUnfairLock<[[LLMMessage]]>(uncheckedState: [])
    var captured: [[LLMMessage]] { requests.withLock { $0 } }

    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
        requests.withLock { $0.append(messages) }
        return LLMResponse(text: "the whole answer at once")
    }

    func streamTurn(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
        nil
    }
}


/// A gate the test opens by hand.
///
/// The streaming turn is blocked on it, so the test decides when the turn
/// may finish. That is what makes "the piece arrived while the turn was
/// still running" observable at all.
final class DeliveryGate: @unchecked Sendable {
    private struct State {
        var isOpen = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { current -> Bool in
                if current.isOpen { return true }
                current.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiter = state.withLock { current -> CheckedContinuation<Void, Never>? in
            current.isOpen = true
            defer { current.waiter = nil }
            return current.waiter
        }
        waiter?.resume()
    }
}

/// Collects the events as they arrive, so the test can look at them while
/// the turn is still running.
final class EventSink: @unchecked Sendable {
    private let events = OSAllocatedUnfairLock<[AgentEvent]>(uncheckedState: [])
    var all: [AgentEvent] { events.withLock { $0 } }
    func append(_ event: AgentEvent) { events.withLock { $0.append(event) } }
    var sawTextDelta: Bool {
        all.contains { if case .assistantTextDelta = $0 { return true } else { return false } }
    }
}

/// A gateway whose stream stops after its first piece until the test opens
/// the gate.
final class GatedStreamingGateway: AgentModelGateway, @unchecked Sendable {
    private let gate: DeliveryGate

    init(gate: DeliveryGate) {
        self.gate = gate
    }

    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
        LLMResponse(text: "not streamed")
    }

    func streamTurn(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.textDelta("Checking"))
                // The turn cannot finish until the test says so.
                await gate.wait()
                continuation.yield(.textDelta(" the disk."))
                continuation.yield(.completed)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Agent streaming turn")
struct AgentStreamingTurnTests {

    private func collect(
        _ runtime: AgentRuntime
    ) async -> [AgentEvent] {
        var collected: [AgentEvent] = []
        for await event in runtime.run(input: "check the disk") { _, _ in ("ok", 0) } {
            collected.append(event)
            if case .completed = event { break }
        }
        return collected
    }

    @Test("The answer reaches the user in pieces, before the tools run")
    func theAnswerArrivesBeforeTheToolsRun() async {
        let gateway = ScriptedStreamingGateway(scripts: [
            [
                .textDelta("Checking "),
                .textDelta("the disk."),
                .toolCall(LLMToolCall(id: "call-1", name: "run_command", argumentsJSON: #"{"command":"df -h"}"#))
            ],
            [.textDelta("All done.")]
        ])
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        let events = await collect(runtime)

        let deltas = events.compactMap { event -> String? in
            if case let .assistantTextDelta(delta) = event { return delta }
            return nil
        }
        #expect(deltas == ["Checking ", "the disk.", "All done."],
                "the pieces of the answer must reach the user as they arrive")

        // And they arrive *before* the tool runs. A runtime that buffered
        // the pieces and emitted them at the end would put them after the
        // tool output — the user would still be waiting for the answer.
        let firstDelta = events.firstIndex { if case .assistantTextDelta = $0 { return true } else { return false } }
        let firstTool = events.firstIndex { if case .toolCallStarted = $0 { return true } else { return false } }
        let deltaIndex = try? #require(firstDelta)
        let toolIndex = try? #require(firstTool)
        #expect(deltaIndex != nil, "the answer must be streamed")
        #expect(toolIndex != nil, "the tool must run")
        #expect((deltaIndex ?? 0) < (toolIndex ?? 0),
                "the pieces must arrive before the tool runs, not after")
    }

    @Test("The first piece is delivered while the turn is still running")
    func theFirstPieceIsDeliveredWhileTheTurnRuns() async {
        let gate = DeliveryGate()
        let sink = EventSink()
        let runtime = AgentRuntime(
            modelGateway: GatedStreamingGateway(gate: gate),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )

        let collector = Task {
            for await event in runtime.run(input: "check the disk") { _, _ in ("ok", 0) } {
                sink.append(event)
                if case .completed = event { break }
            }
        }

        // The gateway is blocked after its first piece, so the turn cannot
        // have finished. If the piece has not been delivered by now, the
        // runtime is holding it back — which is the whole defect.
        var deliveredWhileRunning = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if sink.sawTextDelta {
                deliveredWhileRunning = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Let the turn finish either way, so a failure is a failure and not
        // a hang.
        gate.open()
        await collector.value

        #expect(deliveredWhileRunning,
                "the first piece must reach the user while the turn is still running")
    }

    @Test("The streamed answer is not delivered twice")
    func theAnswerIsNotDeliveredTwice() async {
        let gateway = ScriptedStreamingGateway(scripts: [
            [.textDelta("all done")]
        ])
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        let events = await collect(runtime)

        let fullTexts = events.compactMap { event -> String? in
            if case let .assistantText(text) = event { return text }
            return nil
        }
        #expect(fullTexts.isEmpty,
                "the pieces are the answer; the whole text must not be delivered again")
    }

    @Test("A provider that cannot stream falls back to a whole turn")
    func nonStreamingProviderFallsBack() async {
        let gateway = NonStreamingGateway()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        let events = await collect(runtime)

        let deltas = events.compactMap { event -> String? in
            if case let .assistantTextDelta(delta) = event { return delta }
            return nil
        }
        #expect(deltas.isEmpty, "nothing to stream")
        let texts = events.compactMap { event -> String? in
            if case let .assistantText(text) = event { return text }
            return nil
        }
        #expect(texts == ["the whole answer at once"])
    }

    @Test("The model sees the whole answer in the next turn")
    func theModelSeesTheWholeAnswer() async {
        let gateway = ScriptedStreamingGateway(scripts: [
            [
                .textDelta("Checking "),
                .textDelta("the disk."),
                .toolCall(LLMToolCall(id: "call-1", name: "run_command", argumentsJSON: #"{"command":"df -h"}"#))
            ],
            [.textDelta("All done.")]
        ])
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        _ = await collect(runtime)

        let requests = gateway.captured
        #expect(requests.count >= 2, "the loop must have come back for another turn")
        let secondTurn = requests.last ?? []
        let assistantTurn = secondTurn.first { $0.role == .assistant }
        #expect(assistantTurn?.content == "Checking the disk.",
                "the pieces must be joined back into one answer for the model")
    }

    @Test("The transcript records the answer once")
    func theTranscriptRecordsTheAnswerOnce() async {
        let store = AgentTranscriptStore()
        let gateway = ScriptedStreamingGateway(scripts: [
            [.textDelta("Hello "), .textDelta("world")]
        ])
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            transcriptStore: store
        )
        _ = await collect(runtime)

        let transcript = store.exportTextTranscript()
        #expect(transcript.contains("[Assistant]: Hello world"),
                "the pieces must be joined back into one line")
        #expect(transcript.components(separatedBy: "[Assistant]:").count == 2,
                "the answer must be recorded once, not twice")
    }
}
