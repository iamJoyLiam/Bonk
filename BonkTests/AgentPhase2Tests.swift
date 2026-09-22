//
//  AgentPhase2Tests.swift
//  BonkTests
//
//  Phase 2 acceptance: deterministic fold eligibility (effect-based) first,
//  gate second, dialog last. Only existing .confirmRequired verdicts may
//  enter; L3/L4, unsafe effects, and unseen/denied commands keep the dialog.
//  Folded approvals never train future eligibility. Serialized: tests share
//  the trace ring and engine instances.
//

@testable import Bonk
import Foundation
import Testing

// MARK: - Stub engines

final class StubFoldEngine: DecisionEngine, @unchecked Sendable {
    let engineName = "stub-fold"
    let choiceConfidenceSource = "stub"
    let proceed: Bool

    init(proceed: Bool) { self.proceed = proceed }

    func choose(options: [DecisionOption], context: DecisionContext) async throws -> ChoiceDecision {
        ChoiceDecision(selectedID: nil, confidence: 1.0, rationale: .noCandidate)
    }

    func gate(question: String, context: DecisionContext) async throws -> GateDecision {
        #expect(question == "fold-confirmation")
        return GateDecision(shouldProceed: proceed, confidence: 1.0)
    }

    func score(option: DecisionOption, context: DecisionContext) async throws -> ScoreDecision {
        ScoreDecision(score: 0, confidence: 0)
    }
}

final class ThrowingFoldEngine: DecisionEngine, @unchecked Sendable {
    let engineName = "stub-throw"
    let choiceConfidenceSource = "stub"

    func choose(options: [DecisionOption], context: DecisionContext) async throws -> ChoiceDecision {
        ChoiceDecision(selectedID: nil, confidence: 1.0, rationale: .noCandidate)
    }

    func gate(question: String, context: DecisionContext) async throws -> GateDecision {
        throw NSError(domain: "test", code: -1)
    }

    func score(option: DecisionOption, context: DecisionContext) async throws -> ScoreDecision {
        ScoreDecision(score: 0, confidence: 0)
    }
}

// MARK: - Effect profiler

@Suite("Effect profiler")
struct EffectProfilerTests {
    @Test("Reversible local writes are foldable, destructive ones are not")
    func foldableWrites() {
        #expect(CommandEffectProfiler.profile(command: "mkdir /tmp/x").foldable)
        #expect(CommandEffectProfiler.profile(command: "cp a b").foldable)
        #expect(!CommandEffectProfiler.profile(command: "rm -rf /tmp/x").foldable)
    }

    @Test("Escalation, signals, packages, network, and git mutation never fold")
    func forbidden() {
        #expect(!CommandEffectProfiler.profile(command: "sudo ls /tmp").foldable)
        #expect(!CommandEffectProfiler.profile(command: "kill 1234").foldable)
        #expect(!CommandEffectProfiler.profile(command: "brew install wget").foldable)
        #expect(!CommandEffectProfiler.profile(command: "curl https://example.com").foldable)
        #expect(!CommandEffectProfiler.profile(command: "git push").foldable)
        #expect(CommandEffectProfiler.profile(command: "git status").foldable)
    }

    @Test("Unknown verbs never fold even when harmless-looking")
    func unknownVerbs() {
        let profile = CommandEffectProfiler.profile(command: "frobnicate --all")
        #expect(!profile.knownVerb)
        #expect(!profile.foldable)
    }
}

// MARK: - Eligibility matrix (pure)

@Suite("Fold eligibility")
struct FoldEligibilityTests {
    private func approvedFacts(occurrences: Int = 2) -> CommandDecisionFacts {
        CommandDecisionFacts(
            occurrences: occurrences, allowCount: occurrences,
            denyCount: 0, previousDecision: .approved, lastDecisionAt: Date()
        )
    }

    private func effect(_ command: String) -> CommandEffectProfile {
        CommandEffectProfiler.profile(command: command)
    }

    @Test("L2 reversible write with prior approval is eligible")
    func eligible() {
        let result = ConfirmationFoldEvaluator.check(
            tool: "run_command", level: .l2StateMutation,
            effect: effect("mkdir /tmp/x"), facts: approvedFacts()
        )
        #expect(result == FoldEligibility(eligible: true, reason: .eligible))
    }

    @Test("L3/L4 never reach the gate")
    func levels() {
        for level in [CommandSafetyLevel.l3HighRisk, .l4Critical] as [CommandSafetyLevel] {
            let result = ConfirmationFoldEvaluator.check(
                tool: "run_command", level: level,
                effect: effect("mkdir /tmp/x"), facts: approvedFacts()
            )
            #expect(!result.eligible)
            #expect(result.reason == .levelTooHigh)
        }
    }

    @Test("Unsafe effects stay on the dialog")
    func effects() {
        // Explicit L2 isolates the effect rule from the safety classifier.
        for command in ["rm -rf /tmp/x", "sudo ls /tmp", "curl https://example.com", "git push"] {
            let result = ConfirmationFoldEvaluator.check(
                tool: "run_command", level: .l2StateMutation,
                effect: effect(command), facts: approvedFacts()
            )
            #expect(!result.eligible, "command: \(command)")
            #expect(result.reason == .unsafeEffect)
        }
    }

    @Test("No history or prior denial keeps the dialog")
    func history() {
        let profile = effect("mkdir /tmp/x")
        let unseen = ConfirmationFoldEvaluator.check(tool: "run_command", level: .l2StateMutation, effect: profile, facts: nil)
        #expect(!unseen.eligible)
        #expect(unseen.reason == .noPriorApproval)

        let denied = CommandDecisionFacts(occurrences: 1, allowCount: 0, denyCount: 1, previousDecision: .denied, lastDecisionAt: Date())
        let deniedResult = ConfirmationFoldEvaluator.check(tool: "run_command", level: .l2StateMutation, effect: profile, facts: denied)
        #expect(!deniedResult.eligible)
        #expect(deniedResult.reason == .priorDenial)
    }

    @Test("Non-run_command tools are ineligible without a level")
    func tools() {
        let result = ConfirmationFoldEvaluator.check(tool: "read_file", level: nil, effect: effect("x"), facts: approvedFacts())
        #expect(!result.eligible)
        #expect(result.reason == .unsupportedTool)
    }
}

// MARK: - Shared gate mapping

@Suite("Fold gate", .serialized)
struct FoldGateTests {
    private func facts() -> FoldGateFacts {
        FoldGateFacts(
            tool: "run_command", normalizedCommand: "mkdir /tmp/x",
            safetyLevel: "L2", accessMode: "supervised", semanticTags: "filesystemWrite",
            previousUserDecision: "approved", sameCommandOccurrences: 2, iteration: 0
        )
    }

    @Test("Gate maps proceed/keep and traces both")
    func mapping() async {
        let (fold, _) = await ConfirmationFoldGate.evaluate(
            engine: StubFoldEngine(proceed: true), facts: facts(), threshold: 0.75, task: "agentExecute"
        )
        #expect(fold == .foldConfirmation)
        let (keep, _) = await ConfirmationFoldGate.evaluate(
            engine: StubFoldEngine(proceed: false), facts: facts(), threshold: 0.75, task: "agentExecute"
        )
        #expect(keep == .keepConfirmation)
    }

    @Test("Throwing gate keeps and traces fallback")
    func throwing() async {
        let (disposition, _) = await ConfirmationFoldGate.evaluate(
            engine: ThrowingFoldEngine(), facts: facts(), threshold: 0.75, task: "agentExecute"
        )
        #expect(disposition == .keepConfirmation)
        let events = await DecisionTraceRecorder.shared.recentAgentEvents(limit: 20)
        #expect(events.contains(where: { $0.kind == .decisionFallback && $0.engine == "stub-throw" }))
    }
}

// MARK: - Confirmation reason (UI fact line)

@Suite("Confirmation reason")
struct ConfirmationReasonTests {
    @Test("Reason combines level and history word")
    func words() {
        #expect(ConfirmationReason.describe(safetyLevel: "L2", history: nil).contains("L2"))
        let approved = CommandDecisionFacts(occurrences: 2, allowCount: 2, denyCount: 0, previousDecision: .approved, lastDecisionAt: Date())
        let denied = CommandDecisionFacts(occurrences: 1, allowCount: 0, denyCount: 1, previousDecision: .denied, lastDecisionAt: Date())
        #expect(ConfirmationReason.describe(safetyLevel: "L2", history: approved) != ConfirmationReason.describe(safetyLevel: "L2", history: denied))
        #expect(ConfirmationReason.describe(safetyLevel: "L2", history: denied) != ConfirmationReason.describe(safetyLevel: "L2", history: nil))
    }
}

// MARK: - Runtime fold path (stub engines, serialized on the shared trace ring)

@Suite("Fold runtime", .serialized)
struct FoldRuntimeTests {
    private func approvedMemory(for command: String) async -> (AgentDecisionMemory, String) {
        let memory = AgentDecisionMemory()
        let key = CommandNormalizer.normalizedKey(command)
        await memory.recordEvaluation(key: key)
        await memory.recordDecision(key: key, decision: .approved)
        return (memory, key)
    }

    private func mkdirGateway() -> AgentRuntimeContractTests.MockModelGateway {
        let toolCall = LLMToolCall(id: "call-1", name: "run_command", argumentsJSON: "{\"command\":\"mkdir /tmp/x\"}")
        return AgentRuntimeContractTests.MockModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [toolCall]),
            LLMResponse(text: "done"),
        ])
    }

    private func drainResolvingDialogs(
        stream: AsyncStream<AgentEvent>, runtime: AgentRuntime, approved: Bool = true
    ) async -> [AgentEvent] {
        var collected: [AgentEvent] = []
        for await event in stream {
            if case let .permissionRequested(id, _, _, _) = event {
                runtime.resolvePermission(id: id, approved: approved)
            }
            collected.append(event)
            if case .completed = event { break }
        }
        return collected
    }

    private func hasPermissionRequest(_ events: [AgentEvent]) -> Bool {
        events.contains(where: {
            if case .permissionRequested = $0 { return true }
            return false
        })
    }

    private func resolvedApproved(_ events: [AgentEvent], id: String) -> Bool {
        events.contains(where: {
            if case let .permissionResolved(eventID, approved) = $0 { return eventID == id && approved }
            return false
        })
    }

    private func hasFolded(_ events: [AgentEvent], id: String) -> Bool {
        events.contains(where: {
            if case let .permissionFolded(eventID, _, level, engine) = $0 {
                return eventID == id && level == "L2" && engine == "stub-fold"
            }
            return false
        })
    }

    private func hasAnyDialog(_ events: [AgentEvent]) -> Bool {
        events.contains(where: {
            switch $0 {
            case .permissionRequested: return true
            case .permissionResolved: return true
            default: return false
            }
        })
    }

    @Test("Fold skips the dialog and records a fold fact, not an approval")
    func foldSkipsDialog() async {
        let (memory, _) = await approvedMemory(for: "mkdir /tmp/x")
        let runtime = AgentRuntime(
            modelGateway: mkdirGateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            decisionMemory: memory,
            foldEngine: StubFoldEngine(proceed: true)
        )
        var collected: [AgentEvent] = []
        for await event in runtime.run(input: "fold me") { _, _ in ("ok", 0) } {
            collected.append(event)
            if case .completed = event { break }
        }
        #expect(hasFolded(collected, id: "call-1"))
        #expect(!hasAnyDialog(collected))
    }

    @Test("Folded approvals do not train future eligibility")
    func foldDoesNotTrain() async {
        let (memory, key) = await approvedMemory(for: "mkdir /tmp/x")
        let before = await memory.facts(for: key)
        let runtime = AgentRuntime(
            modelGateway: mkdirGateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            decisionMemory: memory,
            foldEngine: StubFoldEngine(proceed: true)
        )
        for await event in runtime.run(input: "fold me") { _, _ in ("ok", 0) } {
            if case .completed = event { break }
        }
        let after = await memory.facts(for: key)
        #expect(after?.allowCount == before?.allowCount)
        #expect(after?.previousDecision == .approved)
    }

    @Test("Gate keep falls back to the dialog")
    func keepShowsDialog() async {
        let (memory, _) = await approvedMemory(for: "mkdir /tmp/x")
        let runtime = AgentRuntime(
            modelGateway: mkdirGateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            decisionMemory: memory,
            foldEngine: StubFoldEngine(proceed: false)
        )
        let collected = await drainResolvingDialogs(stream: runtime.run(input: "keep me") { _, _ in ("ok", 0) }, runtime: runtime)
        #expect(hasPermissionRequest(collected))
    }

    @Test("Throwing engine never fails open")
    func throwingKeepsDialog() async {
        let (memory, _) = await approvedMemory(for: "mkdir /tmp/x")
        let runtime = AgentRuntime(
            modelGateway: mkdirGateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            decisionMemory: memory,
            foldEngine: ThrowingFoldEngine()
        )
        let collected = await drainResolvingDialogs(stream: runtime.run(input: "throw me") { _, _ in ("ok", 0) }, runtime: runtime)
        #expect(hasPermissionRequest(collected))
    }

    @Test("Nil engine preserves Phase 1 dialog behavior")
    func nilEngineKeepsDialog() async {
        let (memory, _) = await approvedMemory(for: "mkdir /tmp/x")
        let runtime = AgentRuntime(
            modelGateway: mkdirGateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            decisionMemory: memory,
            foldEngine: nil
        )
        let collected = await drainResolvingDialogs(stream: runtime.run(input: "nil me") { _, _ in ("ok", 0) }, runtime: runtime)
        #expect(hasPermissionRequest(collected))
    }

    @Test("Fold leaves eligible/resolved trace without command text")
    func foldTrace() async {
        await DecisionTraceRecorder.shared.resetAgentEvents()
        let (memory, _) = await approvedMemory(for: "mkdir /tmp/x")
        let runtime = AgentRuntime(
            modelGateway: mkdirGateway(),
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            decisionMemory: memory,
            foldEngine: StubFoldEngine(proceed: true)
        )
        for await event in runtime.run(input: "trace me") { _, _ in ("ok", 0) } {
            if case .completed = event { break }
        }
        let events = await DecisionTraceRecorder.shared.recentAgentEvents(limit: 20)
        #expect(events.contains(where: { $0.kind == .confirmationFoldable && $0.result.contains("eligible") }))
        #expect(events.contains(where: { $0.kind == .decisionRequested }))
        #expect(events.contains(where: { $0.kind == .decisionResolved && $0.result == "fold" }))
    }
}

// MARK: - Plan-step fold path

@Suite("Fold plan steps", .serialized)
struct FoldPlanStepTests {
    @MainActor
    private func engineWithApproval(for command: String) async -> (AgentEngine, String) {
        let engine = AgentEngine(executionManager: .shared)
        let key = CommandNormalizer.normalizedKey(command)
        await engine.decisionMemory.recordEvaluation(key: key)
        await engine.decisionMemory.recordDecision(key: key, decision: .approved)
        return (engine, key)
    }

    @Test("Eligible moderate step folds with a willing engine")
    func moderateFolds() async {
        let (engine, _) = await engineWithApproval(for: "mkdir /tmp/x")
        let step = AgentPlan.Step(description: "make dir", command: "mkdir /tmp/x", riskLevel: .moderate)
        let folded = await engine.tryFoldPlanStep(step: step, index: 0, engine: StubFoldEngine(proceed: true))
        #expect(folded)
    }

    @Test("Dangerous steps never reach the gate")
    func dangerousKeeps() async {
        let (engine, _) = await engineWithApproval(for: "rm -rf /tmp/x")
        let step = AgentPlan.Step(description: "delete", command: "rm -rf /tmp/x", riskLevel: .dangerous)
        let folded = await engine.tryFoldPlanStep(step: step, index: 0, engine: StubFoldEngine(proceed: true))
        #expect(!folded)
    }

    @Test("Unseen commands keep the dialog even with a willing engine")
    func unseenKeeps() async {
        let engine = await AgentEngine(executionManager: .shared)
        let step = AgentPlan.Step(description: "make dir", command: "mkdir /tmp/unseen", riskLevel: .moderate)
        let folded = await engine.tryFoldPlanStep(step: step, index: 0, engine: StubFoldEngine(proceed: true))
        #expect(!folded)
    }

    @Test("Plan fold leaves agentPlan task trace")
    func planTrace() async {
        await DecisionTraceRecorder.shared.resetAgentEvents()
        let (engine, _) = await engineWithApproval(for: "mkdir /tmp/x")
        let step = AgentPlan.Step(description: "make dir", command: "mkdir /tmp/x", riskLevel: .moderate)
        let folded = await engine.tryFoldPlanStep(step: step, index: 1, engine: StubFoldEngine(proceed: true))
        #expect(folded)
        let events = await DecisionTraceRecorder.shared.recentAgentEvents(limit: 20)
        #expect(hasResolvedFold(events, task: "agentPlan"))
    }

    private func hasResolvedFold(_ events: [AgentTraceEvent], task: String) -> Bool {
        events.contains(where: { $0.kind == .decisionResolved && $0.task == task && $0.result == "fold" })
    }
}
