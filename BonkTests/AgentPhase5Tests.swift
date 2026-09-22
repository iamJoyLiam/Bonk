//
//  AgentPhase5Tests.swift
//  BonkTests
//
//  Phase 5 acceptance: reported usage is the authoritative budget source
//  (nil stays unknown, never zero); enforcement only adds halts; compaction
//  shrinks stale outputs and summarizes at safe boundaries without
//  orphaning tool messages. Estimates are hints, never budget truth.
//  Serialized: tests share the trace ring.
//

@testable import Bonk
import Foundation
import os
import Testing

// MARK: - Recording gateway (observes model inputs)

final class RecordingGateway: AgentModelGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [LLMResponse]
    private(set) var seen: [[LLMMessage]] = []

    init(_ responses: [LLMResponse]) { self.responses = responses }

    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
        lock.withLock { seen.append(messages) }
        return lock.withLock { responses.isEmpty ? LLMResponse(text: "default") : responses.removeFirst() }
    }

    func stream(messages: [LLMMessage]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Stub provider (usage plumbing link)

final class StubUsageProvider: LLMProvider, @unchecked Sendable {
    let providerID = UUID()
    let providerName = "stub"
    let capability = LLMProviderCapability(supportsStreaming: false, supportsToolCalls: true)
    let usage: TokenUsage?

    init(usage: TokenUsage?) { self.usage = usage }

    func chat(messages: [LLMMessage], maxTokens: Int?, disableReasoning: Bool) async throws -> LLMResponse {
        LLMResponse(text: "hi", usage: usage)
    }

    func stream(messages: [LLMMessage], maxTokens: Int?, disableReasoning: Bool) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func toolCall(messages: [LLMMessage], tools: [LLMToolDefinition], maxTokens: Int?) async throws -> LLMResponse {
        LLMResponse(text: "", usage: usage)
    }

    func listModels() async throws -> [String] { [] }
    func testConnection() async throws -> Bool { true }
}

// MARK: - Usage parsing

@Suite("Usage parsing")
struct UsageParsingTests {
    @Test("Chat completions usage maps to TokenUsage")
    func chatCompletions() {
        let usage = TokenUsage.chatCompletions(from: [
            "usage": ["prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30],
        ])
        #expect(usage == TokenUsage(inputTokens: 10, outputTokens: 20, totalTokens: 30))
        #expect(TokenUsage.chatCompletions(from: [:]) == nil)
        #expect(TokenUsage.chatCompletions(from: ["usage": ["other": 1]]) == nil)
    }

    @Test("Responses API usage maps to TokenUsage")
    func responsesAPI() {
        let usage = TokenUsage.responsesAPI(from: [
            "usage": ["input_tokens": 5, "output_tokens": 7, "total_tokens": 12],
        ])
        #expect(usage == TokenUsage(inputTokens: 5, outputTokens: 7, totalTokens: 12))
        #expect(TokenUsage.responsesAPI(from: [:]) == nil)
    }

    @Test("Agent turn parser carries usage through")
    func agentTurn() throws {
        let payload: [String: Any] = [
            "choices": [["message": ["content": "hi", "tool_calls": []]]],
            "usage": ["prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let turn = try AIProviderNetworking.parseAgentTurn(from: data)
        #expect(turn.usage?.inputTokens == 3)
        #expect(turn.usage?.outputTokens == 4)
    }

    @Test("Gateway passes provider usage into the runtime")
    func gatewayPassthrough() async throws {
        let gateway = LLMProviderModelGateway(provider: StubUsageProvider(
            usage: TokenUsage(inputTokens: 11, outputTokens: 22, totalTokens: 33)
        ))
        let response = try await gateway.chat(messages: [.user("hi")], tools: [])
        #expect(response.usage?.inputTokens == 11)
        #expect(response.usage?.outputTokens == 22)
    }
}

// MARK: - Budget accounting + enforcement (pure)

@Suite("Token budget")
struct TokenBudgetTests {
    @Test("Reported usage accumulates, nil stays unknown")
    func accumulation() {
        var budget = AgentBudgetController()
        #expect(budget.recordUsage(nil).isEmpty)
        #expect(budget.snapshot.inputTokens == 0)
        let warnings = budget.recordUsage(TokenUsage(inputTokens: 170_000, outputTokens: 1_000, totalTokens: 171_000))
        #expect(budget.snapshot.inputTokens == 170_000)
        #expect(budget.snapshot.outputTokens == 1_000)
        #expect(warnings.contains(.inputTokensHigh(used: 170_000, max: 200_000)))
    }

    @Test("Partial usage counts what was reported")
    func partial() {
        var budget = AgentBudgetController()
        _ = budget.recordUsage(TokenUsage(outputTokens: 60_000))
        #expect(budget.snapshot.inputTokens == 0)
        #expect(budget.exceededReason() == .outputTokens)
    }

    @Test("Unset caps and unknown usage never halt")
    func neverHaltsUnknown() {
        var budget = AgentBudgetController(maxInputTokens: nil, maxOutputTokens: nil)
        _ = budget.recordUsage(nil)
        #expect(budget.exceededReason() == nil)
        var iterations = AgentBudgetController(maxIterations: 1_000_000)
        _ = iterations.recordIteration()
        #expect(iterations.exceededReason() == nil)
    }

    @Test("Iteration overrun trips only past the bound, never on the final round")
    func iterationOverrun() {
        var budget = AgentBudgetController(maxIterations: 2)
        _ = budget.recordIteration()
        _ = budget.recordIteration()
        // Exactly at the bound: the loop's final round still runs.
        #expect(budget.exceededReason() == nil)
        _ = budget.recordIteration()
        #expect(budget.exceededReason() == .iterations)
    }

    @Test("Estimates are hints with the documented ratio")
    func estimator() {
        let messages = [LLMMessage.user(String(repeating: "x", count: 400))]
        #expect(TokenEstimator.estimatedInputTokens(for: messages) == 100)
    }
}

// MARK: - Runtime integration (serialized on the shared trace ring)

@Suite("Budget runtime", .serialized)
struct BudgetRuntimeTests {
    private func toolResponses(_ count: Int, usage: TokenUsage? = nil) -> [LLMResponse] {
        var responses = (1 ... count).map { index in
            LLMResponse(
                text: "",
                toolCalls: [LLMToolCall(
                    id: "call-\(index)", name: "run_command",
                    argumentsJSON: "{\"command\":\"uptime\"}"
                )],
                usage: usage
            )
        }
        responses.append(LLMResponse(text: "conclusion"))
        return responses
    }

    private func drain(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var collected: [AgentEvent] = []
        for await event in stream {
            collected.append(event)
            if case .completed = event { break }
        }
        return collected
    }

    private func hasBudgetError(_ events: [AgentEvent]) -> Bool {
        events.contains(where: {
            if case let .error(text) = $0 { return text.contains("budget exceeded") }
            return false
        })
    }

    @Test("Loop bound still runs exactly maxIterations rounds")
    func loopBoundIntact() async {
        let gateway = RecordingGateway(toolResponses(5))
        let runtime = AgentRuntime(modelGateway: gateway, maxIterations: 2)
        let events = await drain(runtime.run(input: "bound me") { _, _ in ("ok", 0) })
        #expect(!hasBudgetError(events))
        #expect(events.contains(.assistantText("conclusion")))
    }

    @Test("Reported token blowout halts before any tool runs")
    func tokenHalt() async {
        let big = TokenUsage(inputTokens: 300_000, outputTokens: 10, totalTokens: 300_010)
        let gateway = RecordingGateway(toolResponses(3, usage: big))
        let runtime = AgentRuntime(modelGateway: gateway)
        let events = await drain(runtime.run(input: "expensive") { _, _ in ("ok", 0) })
        #expect(hasBudgetError(events))
    }

    @Test("Usage accumulates into runtime state")
    func accumulation() async {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 50, totalTokens: 1_050)
        let gateway = RecordingGateway(toolResponses(1, usage: usage))
        let runtime = AgentRuntime(modelGateway: gateway)
        _ = await drain(runtime.run(input: "count me") { _, _ in ("ok", 0) })
        #expect(runtime.currentState.budget.inputTokens == 1_000)
        #expect(runtime.currentState.budget.outputTokens == 50)
    }

    @Test("Stale tool outputs shrink in place with a marker")
    func shrink() async {
        let longOutput = String(repeating: "x", count: 5_000)
        let gateway = RecordingGateway(toolResponses(5, usage: TokenUsage(inputTokens: 1_000)))
        let runtime = AgentRuntime(modelGateway: gateway)
        _ = await drain(runtime.run(input: "shrink me") { _, _ in (longOutput, 0) })
        let seen = gateway.seen
        #expect(seen.count == 6)
        let lastInputs = seen.last?.map(\.content).joined(separator: "\n") ?? ""
        #expect(lastInputs.contains("[…compacted]"))
    }

    @Test("Summary compaction fires at safe boundaries with huge inputs")
    func summary() async {
        let big = TokenUsage(inputTokens: 70_000, outputTokens: 10, totalTokens: 70_010)
        var responses = toolResponses(2, usage: big)
        responses.insert(LLMResponse(text: "summ"), at: 2)
        let gateway = RecordingGateway(responses)
        let runtime = AgentRuntime(modelGateway: gateway)
        _ = await drain(runtime.run(input: "summarize me") { _, _ in ("ok", 0) })
        let seen = gateway.seen
        let summaryRequests = seen.filter { msgs in
            msgs.first?.content.hasPrefix("Summarize") ?? false
        }
        #expect(summaryRequests.count == 1)
        let lastInputs = seen.last?.map(\.content).joined(separator: "\n") ?? ""
        #expect(lastInputs.contains("Earlier context (compacted)"))
    }

    @Test("Halt leaves a budget trace")
    func haltTrace() async {
        await DecisionTraceRecorder.shared.resetAgentEvents()
        let big = TokenUsage(inputTokens: 300_000, outputTokens: 10, totalTokens: 300_010)
        let gateway = RecordingGateway(toolResponses(3, usage: big))
        let runtime = AgentRuntime(modelGateway: gateway)
        _ = await drain(runtime.run(input: "trace halt") { _, _ in ("ok", 0) })
        let events = await DecisionTraceRecorder.shared.recentAgentEvents(limit: 20)
        #expect(events.contains(where: { $0.kind == .budgetExceeded }))
    }
}
