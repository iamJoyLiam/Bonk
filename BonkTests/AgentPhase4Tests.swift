//
//  AgentPhase4Tests.swift
//  BonkTests
//
//  Decision Phase 4 acceptance: legacy plan path intelligence.
//  Effect attached at parse (computed, never model-supplied),
//  unexecutable plans skip approval, and consecutive failures meet
//  the continue/abort gate. choose/score are explicitly deferred:
//  reordering changes plan semantics, scoring needs calibration.
//  Serialized: tests share engine instances and the trace ring.
//

@testable import Bonk
import Foundation
import Testing

@Suite("Plan intelligence", .serialized)
struct PlanIntelligenceTests {
    private func step(_ command: String, risk: CommandSafety) -> AgentPlan.Step {
        AgentPlan.Step(description: "step", command: command, riskLevel: risk)
    }

    @Test("Effect derives from the command, never from model output")
    func effectAttached() {
        #expect(step("mkdir /tmp/x", risk: .moderate).effect.foldable)
        #expect(!step("rm -rf /tmp/x", risk: .dangerous).effect.foldable)
        #expect(!step("sudo ls", risk: .dangerous).effect.foldable)
    }

    @Test("Unexecutable means every step blocked")
    func unexecutable() {
        let allBlocked = AgentPlan(
            thinking: nil,
            steps: [step("sudo mkfs /dev/x", risk: .blocked)],
            summary: "s"
        )
        #expect(allBlocked.isUnexecutable)
        let mixed = AgentPlan(
            thinking: nil,
            steps: [step("sudo mkfs /dev/x", risk: .blocked), step("ls", risk: .safe)],
            summary: "s"
        )
        #expect(!mixed.isUnexecutable)
        let empty = AgentPlan(thinking: nil, steps: [], summary: "s")
        #expect(!empty.isUnexecutable)
        let allSafe = AgentPlan(thinking: nil, steps: [step("ls", risk: .safe)], summary: "s")
        #expect(!allSafe.isUnexecutable)
    }

    @MainActor
    private func freshEngine() -> AgentEngine {
        AgentEngine(executionManager: .shared)
    }

    @Test("First failure continues without consulting the engine")
    func firstFailureSkipsGate() async {
        let engine = await freshEngine()
        // Stub would abort if consulted — true proves it was skipped.
        let cont = await engine.gatePlanContinue(
            command: "mkdir /tmp/x", consecutiveFailures: 1,
            remainingSteps: 2, stepIndex: 0, engine: StubFoldEngine(proceed: false)
        )
        #expect(cont)
    }

    @Test("Second consecutive failure aborts on gate keep")
    func secondFailureAborts() async {
        let engine = await freshEngine()
        let abort = await engine.gatePlanContinue(
            command: "mkdir /tmp/x", consecutiveFailures: 2,
            remainingSteps: 1, stepIndex: 1, engine: StubFoldEngine(proceed: false)
        )
        #expect(!abort)
        let cont = await engine.gatePlanContinue(
            command: "mkdir /tmp/x", consecutiveFailures: 2,
            remainingSteps: 1, stepIndex: 1, engine: StubFoldEngine(proceed: true)
        )
        #expect(cont)
    }

    @Test("Gate errors preserve legacy continue behavior")
    func errorContinues() async {
        let engine = await freshEngine()
        let cont = await engine.gatePlanContinue(
            command: "mkdir /tmp/x", consecutiveFailures: 3,
            remainingSteps: 0, stepIndex: 2, engine: ThrowingFoldEngine()
        )
        #expect(cont)
    }

    @Test("Abort leaves agentPlan trace")
    func abortTrace() async {
        await DecisionTraceRecorder.shared.resetAgentEvents()
        let engine = await freshEngine()
        let abort = await engine.gatePlanContinue(
            command: "mkdir /tmp/x", consecutiveFailures: 2,
            remainingSteps: 1, stepIndex: 1, engine: StubFoldEngine(proceed: false)
        )
        #expect(!abort)
        let events = await DecisionTraceRecorder.shared.recentAgentEvents(limit: 20)
        let requested = events.contains(where: { $0.kind == .decisionRequested && $0.task == "agentPlan" })
        #expect(requested)
        #expect(hasAbortPlan(events))
    }

    private func hasAbortPlan(_ events: [AgentTraceEvent]) -> Bool {
        events.contains(where: { $0.kind == .decisionResolved && $0.task == "agentPlan" && $0.result == "abort-plan" })
    }
}
