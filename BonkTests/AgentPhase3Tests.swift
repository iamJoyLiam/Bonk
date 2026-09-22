//
//  AgentPhase3Tests.swift
//  BonkTests
//
//  Phase 3 acceptance: Tier-1 cheap diff runs every step, Tier-2 engine
//  score runs only inside the suspicious window (high similarity, no exit
//  change, twice in a row), and only low progress scores break the loop.
//  Guard behavior is untouched; nil/throwing engines never break.
//  Serialized: tests share the trace ring.
//

@testable import Bonk
import Foundation
import os
import Testing

// MARK: - Stub score engine

final class StubScoreEngine: DecisionEngine, @unchecked Sendable {
    let engineName = "stub-score"
    let choiceConfidenceSource = "stub"
    let scoreValue: Double

    init(scoreValue: Double) { self.scoreValue = scoreValue }

    func choose(options: [DecisionOption], context: DecisionContext) async throws -> ChoiceDecision {
        ChoiceDecision(selectedID: nil, confidence: 1.0, rationale: .noCandidate)
    }

    func gate(question: String, context: DecisionContext) async throws -> GateDecision {
        GateDecision(shouldProceed: true, confidence: 1.0)
    }

    func score(option: DecisionOption, context: DecisionContext) async throws -> ScoreDecision {
        ScoreDecision(score: scoreValue, confidence: 1.0)
    }
}

final class ThrowingScoreEngine: DecisionEngine, @unchecked Sendable {
    let engineName = "stub-score-throw"
    let choiceConfidenceSource = "stub"

    func choose(options: [DecisionOption], context: DecisionContext) async throws -> ChoiceDecision {
        ChoiceDecision(selectedID: nil, confidence: 1.0, rationale: .noCandidate)
    }

    func gate(question: String, context: DecisionContext) async throws -> GateDecision {
        GateDecision(shouldProceed: true, confidence: 1.0)
    }

    func score(option: DecisionOption, context: DecisionContext) async throws -> ScoreDecision {
        throw NSError(domain: "test", code: -1)
    }
}

// MARK: - Tier-1 diff

@Suite("Progress diff")
struct ProgressDiffTests {
    @Test("Identical outputs score 1.0 with no exit change")
    func identical() {
        let signal = ProgressEvaluator.diffSignal(current: "a\nb", previous: "a\nb", exitCodeChanged: false)
        #expect(signal.similarity == 1.0)
        #expect(!signal.exitCodeChanged)
        #expect(signal.addedLines == 0)
        #expect(signal.removedLines == 0)
    }

    @Test("Different outputs score low and count line deltas")
    func different() {
        let signal = ProgressEvaluator.diffSignal(current: "a\nb", previous: "c\nd", exitCodeChanged: true)
        #expect(signal.similarity == 0.0)
        #expect(signal.exitCodeChanged)
        #expect(signal.addedLines == 2)
        #expect(signal.removedLines == 2)
    }

    @Test("Empty pair is identical, not a divide-by-zero")
    func empty() {
        let signal = ProgressEvaluator.diffSignal(current: "", previous: "", exitCodeChanged: false)
        #expect(signal.similarity == 1.0)
    }
}

// MARK: - Suspicious window + judgment mapping

@Suite("Progress window")
struct ProgressWindowTests {
    private func lines(_ names: [String]) -> String { names.joined(separator: "\n") }

    private func base() -> [String] { (1 ... 20).map { "L\($0)" } }

    @Test("First observation only baselines")
    func baseline() {
        var evaluator = ProgressEvaluator()
        let assessment = evaluator.observe(
            callId: "c1", tool: "run_command", actionKey: "ls", exitCode: 0,
            output: lines(base()), goal: "g", iteration: 0
        )
        #expect(assessment == .continue)
    }

    @Test("Two suspicious observations open the judgment window")
    func window() {
        var evaluator = ProgressEvaluator()
        var base = base()
        _ = evaluator.observe(callId: "c1", tool: "run_command", actionKey: "ls", exitCode: 0, output: lines(base), goal: "g", iteration: 0)
        base[19] = "X"
        let second = evaluator.observe(callId: "c2", tool: "run_command", actionKey: "ls", exitCode: 0, output: lines(base), goal: "g", iteration: 1)
        #expect(second == .continue)
        base[19] = "Y"
        let third = evaluator.observe(callId: "c3", tool: "run_command", actionKey: "ls", exitCode: 0, output: lines(base), goal: "g", iteration: 2)
        guard case let .needsJudgment(option, context) = third else {
            Issue.record("expected needsJudgment on the second suspicious step")
            return
        }
        #expect(option.id == "c3")
        #expect(option.label == "ls")
        #expect(context.facts["goal"] == "g")
        #expect(context.facts["failureStreak"] == "0")
    }

    @Test("Exit change or dissimilar output resets the window")
    func reset() {
        var evaluator = ProgressEvaluator()
        var base = base()
        _ = evaluator.observe(callId: "c1", tool: "run_command", actionKey: "ls", exitCode: 0, output: lines(base), goal: "g", iteration: 0)
        base[19] = "X"
        _ = evaluator.observe(callId: "c2", tool: "run_command", actionKey: "ls", exitCode: 0, output: lines(base), goal: "g", iteration: 1)
        // Exit change breaks the streak: next similar pair restarts at one.
        _ = evaluator.observe(callId: "c3", tool: "run_command", actionKey: "ls", exitCode: 1, output: lines(base), goal: "g", iteration: 2)
        base[19] = "Y"
        let fourth = evaluator.observe(callId: "c4", tool: "run_command", actionKey: "ls", exitCode: 1, output: lines(base), goal: "g", iteration: 3)
        #expect(fourth == .continue)
    }

    @Test("Judgment mapping honors the threshold boundary")
    func judgment() {
        let evaluator = ProgressEvaluator()
        #expect(evaluator.recordJudgment(score: 0.1) != .continue)
        #expect(evaluator.recordJudgment(score: 0.9) == .continue)
        // Boundary is inclusive: at-threshold still breaks.
        if case .breakLoop = evaluator.recordJudgment(score: 0.3) {} else {
            Issue.record("expected breakLoop at the boundary")
        }
    }
}

// MARK: - Runtime integration (serialized on the shared trace ring)

@Suite("Progress runtime", .serialized)
struct ProgressRuntimeTests {
    private func base() -> [String] { (1 ... 20).map { "L\($0)" } }

    private func gateway() -> AgentRuntimeContractTests.MockModelGateway {
        let cmds = ["ls /a", "ls /b", "ls /c"]
        var responses = cmds.enumerated().map { index, cmd in
            LLMResponse(text: "", toolCalls: [LLMToolCall(
                id: "call-\(index + 1)", name: "run_command",
                argumentsJSON: "{\"command\":\"\(cmd)\"}"
            )])
        }
        responses.append(LLMResponse(text: "conclusion"))
        return AgentRuntimeContractTests.MockModelGateway(responses: responses)
    }

    private func outputs() -> [String] {
        var a = base()
        var b = base(); b[19] = "X"
        var c = base(); c[19] = "Y"
        return [a.joined(separator: "\n"), b.joined(separator: "\n"), c.joined(separator: "\n")]
    }

    private func run(runtime: AgentRuntime, outputs: [String]) async -> (events: [AgentEvent], execCount: Int) {
        let count = OSAllocatedUnfairLock(uncheckedState: 0)
        let queue = outputs
        var collected: [AgentEvent] = []
        for await event in runtime.run(input: "progress me") { _, _ in
            let index = count.withLock { i -> Int in
                let current = i
                i += 1
                return current
            }
            return (queue[min(index, queue.count - 1)], 0)
        } {
            collected.append(event)
            if case .completed = event { break }
        }
        return (collected, count.withLock { $0 })
    }

    private func hasProgressError(_ events: [AgentEvent]) -> Bool {
        events.contains(where: {
            if case let .error(code, text) = $0 { return code == .progressStall && text.contains("progress") }
            return false
        })
    }

    @Test("Low progress score breaks after the third similar tool")
    func breakOnStall() async {
        let runtime = AgentRuntime(
            modelGateway: gateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            progressEngine: StubScoreEngine(scoreValue: 0.1)
        )
        let (events, execCount) = await run(runtime: runtime, outputs: outputs())
        #expect(execCount == 3)
        #expect(hasProgressError(events))
    }

    @Test("Healthy score continues to normal completion")
    func continueOnProgress() async {
        let runtime = AgentRuntime(
            modelGateway: gateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            progressEngine: StubScoreEngine(scoreValue: 0.9)
        )
        let (events, execCount) = await run(runtime: runtime, outputs: outputs())
        #expect(execCount == 3)
        #expect(!hasProgressError(events))
        #expect(events.contains(.assistantText("conclusion")))
    }

    @Test("Nil engine preserves guard-only behavior")
    func nilEngine() async {
        let runtime = AgentRuntime(
            modelGateway: gateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            progressEngine: nil
        )
        let (events, execCount) = await run(runtime: runtime, outputs: outputs())
        #expect(execCount == 3)
        #expect(!hasProgressError(events))
    }

    @Test("Throwing score engine never fails open into a break")
    func throwingContinues() async {
        let runtime = AgentRuntime(
            modelGateway: gateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            progressEngine: ThrowingScoreEngine()
        )
        let (events, execCount) = await run(runtime: runtime, outputs: outputs())
        #expect(execCount == 3)
        #expect(!hasProgressError(events))
        #expect(events.contains(.assistantText("conclusion")))
    }

    @Test("Stall break leaves score trace")
    func stallTrace() async {
        await DecisionTraceRecorder.shared.resetAgentEvents()
        let runtime = AgentRuntime(
            modelGateway: gateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            progressEngine: StubScoreEngine(scoreValue: 0.1)
        )
        _ = await run(runtime: runtime, outputs: outputs())
        let events = await DecisionTraceRecorder.shared.recentAgentEvents(limit: 20)
        #expect(events.contains(where: { $0.kind == .decisionRequested && $0.result == "progress-score" }))
        #expect(events.contains(where: { $0.kind == .decisionResolved && $0.result == "progress-break" }))
    }
}
