//
//  AgentPhase1Tests.swift
//  BonkTests
//
//  Phase 1 acceptance: infrastructure only, zero behavior change.
//  Router equivalence, state ownership, budget warnings (never enforcement),
//  deterministic normalizer/tagger, fact-only memory, agent trace events.
//  No network, no model.
//

@testable import Bonk
import Foundation
import Testing

// MARK: - Router equivalence (P1-1)

@Suite("Agent router")
struct AgentRouterTests {
    private func provider(type: AIProviderType, name: String) -> AIProviderConfig {
        AIProviderConfig(name: name, type: type, model: "test", endpoint: "https://example.com")
    }

    @Test("Single tool-capable provider routes deterministicSingle")
    @MainActor func singleProvider() {
        let router = ModelRouter(store: AIProviderStore.shared)
        let providers = [provider(type: .openAI, name: "oai")]
        let ctx = RouterContext(task: .agentExecute, contextSize: 100, latencyBudgetMs: 15_000, requiresCapability: "toolCalls")
        let routed = router.routeDeterministic(task: .agentExecute, providers: providers, context: ctx)
        #expect(routed?.provider.name == "oai")
        #expect(routed?.source == .deterministicSingle)
    }

    @Test("Preferred active provider wins the rank")
    @MainActor func preferredWins() {
        let router = ModelRouter(store: AIProviderStore.shared)
        let active = provider(type: .openAI, name: "active")
        let other = provider(type: .claude, name: "other")
        let ctx = RouterContext(task: .agentExecute, contextSize: 100, latencyBudgetMs: 15_000, requiresCapability: "toolCalls")
        let routed = router.routeDeterministic(
            task: .agentExecute, providers: [other, active], context: ctx, preferredID: active.id
        )
        #expect(routed?.provider.id == active.id)
    }

    @Test("Empty provider list routes nil so the caller falls back")
    @MainActor func emptyFallsBack() {
        let router = ModelRouter(store: AIProviderStore.shared)
        let ctx = RouterContext(task: .agentExecute, contextSize: 100, latencyBudgetMs: 15_000, requiresCapability: "toolCalls")
        #expect(router.routeDeterministic(task: .agentExecute, providers: [], context: ctx) == nil)
    }
}

// MARK: - Normalizer + tagger (deterministic facts)

@Suite("Command normalizer")
struct CommandNormalizerTests {
    @Test("Whitespace and home collapse to the same key")
    func sameOperationSameKey() {
        let a = CommandNormalizer.normalizedKey("ls   -la  ~/foo")
        let b = CommandNormalizer.normalizedKey("ls -la <home>/foo")
        #expect(a == b)
    }

    @Test("Different operations keep different keys")
    func differentOperations() {
        #expect(CommandNormalizer.normalizedKey("rm -rf /tmp/a") != CommandNormalizer.normalizedKey("rm -rf /tmp/b"))
    }

    @Test("Keys are length-bounded")
    func bounded() {
        #expect(CommandNormalizer.normalizedKey(String(repeating: "x", count: 1000)).count <= 256)
    }
}

@Suite("Semantic tagger")
struct SemanticTaggerTests {
    @Test("Read verbs tag filesystemRead")
    func readVerbs() {
        #expect(SemanticTagger.tag(command: "ls -la /tmp").contains(.filesystemRead))
        #expect(SemanticTagger.tag(command: "cat /etc/hosts").contains(.filesystemRead))
    }

    @Test("Redirects imply a write")
    func redirectWrite() {
        #expect(SemanticTagger.tag(command: "echo hi > /tmp/f").contains(.filesystemWrite))
    }

    @Test("sudo tags escalation plus the underlying operation")
    func sudo() {
        let tags = SemanticTagger.tag(command: "sudo rm -rf /tmp/x")
        #expect(tags.contains(.privilegeEscalation))
        #expect(tags.contains(.filesystemDelete))
    }

    @Test("git verbs split read vs mutate")
    func git() {
        #expect(SemanticTagger.tag(command: "git status").contains(.gitRead))
        #expect(SemanticTagger.tag(command: "git commit -m x").contains(.gitMutate))
    }

    @Test("Install verbs tag packageInstall")
    func packages() {
        #expect(SemanticTagger.tag(command: "brew install wget").contains(.packageInstall))
        #expect(SemanticTagger.tag(command: "curl https://example.com").contains(.networkAccess))
    }

    @Test("Low-risk set stays read-only")
    func lowRisk() {
        #expect(SemanticTagger.lowRiskTags == [.filesystemRead, .gitRead])
    }

    @Test("Unknown verbs fall back to processExecute, never empty")
    func unknownNeverEmpty() {
        #expect(!SemanticTagger.tag(command: "frobnicate --all").isEmpty)
    }
}

// MARK: - State, budget, memory (skeletons)

@Suite("Agent state")
struct AgentStateTests {
    @Test("Steps drive progress counters, observations stay bounded")
    func population() {
        var state = AgentState(goal: "test")
        state.appendStep(AgentStepState(tool: "run_command", normalizedKey: "ls", exitCode: 0, outputSummary: "ok"))
        state.appendStep(AgentStepState(tool: "run_command", normalizedKey: "false", exitCode: 1, outputSummary: "fail"))
        #expect(state.progress.completedSteps == 1)
        #expect(state.progress.failedSteps == 1)
        #expect(state.progress.lastExitCode == 1)
        for i in 0 ..< 25 {
            state.appendObservation(AgentObservation(kind: .toolOutput, text: "line \(i)"))
        }
        #expect(state.observations.count == AgentObservation.maxObservations)
        #expect(state.observations.allSatisfy { $0.text.count <= AgentObservation.maxTextLength })
    }
}

@Suite("Budget controller")
struct BudgetControllerTests {
    @Test("Warnings fire once and never block")
    func warningsOnce() {
        var budget = AgentBudgetController(maxIterations: 10, maxWallClockMs: 3_600_000, maxDecisionCalls: 10)
        var seen: [BudgetWarning] = []
        for _ in 0 ..< 10 { seen.append(contentsOf: budget.recordIteration()) }
        #expect(seen.count == 1)
        // Loop still runs past the warning: no enforcement in Phase 1.
        seen.append(contentsOf: budget.recordIteration())
        #expect(seen.count == 1)
        #expect(budget.snapshot.iterations == 11)
    }
}

@Suite("Decision memory")
struct DecisionMemoryTests {
    @Test("Records facts only: occurrences, verdicts, timestamps")
    func factsOnly() async {
        let memory = AgentDecisionMemory()
        await memory.recordEvaluation(key: "ls")
        await memory.recordEvaluation(key: "ls")
        await memory.recordDecision(key: "ls", decision: .approved)
        let facts = await memory.facts(for: "ls")
        #expect(facts?.occurrences == 2)
        #expect(facts?.allowCount == 1)
        #expect(facts?.denyCount == 0)
        #expect(facts?.previousDecision == .approved)
        #expect(facts?.lastDecisionAt != nil)
        #expect(await memory.facts(for: "unknown") == nil)
    }
}

// MARK: - Agent trace events

@Suite("Agent trace events")
struct AgentTraceEventTests {
    @Test("Agent ring records, counts, and resets independently")
    func ring() async {
        let recorder = DecisionTraceRecorder.shared
        await recorder.resetAgentEvents()
        await recorder.recordAgentEvent(AgentTraceEvent(kind: .routerSelected, engine: "router", task: "agentExecute", result: "deterministicSingle"))
        await recorder.recordAgentEvent(AgentTraceEvent(kind: .budgetWarning, engine: "budget", task: "agentExecute", result: "iterations-20/25"))
        let counts = await recorder.agentEventCounts()
        #expect(counts["router.selected"] == 1)
        #expect(counts["budget.warning"] == 1)
        #expect(await recorder.recentAgentEvents(limit: 5).count == 2)
        await recorder.resetAgentEvents()
        #expect(await recorder.recentAgentEvents().isEmpty)
    }
}
