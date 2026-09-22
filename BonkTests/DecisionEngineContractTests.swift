//
//  DecisionEngineContractTests.swift
//  BonkTests
//
//  Phase-1 acceptance tests for the Decision Intelligence foundation.
//  No network, no model: every test runs against DeterministicDecisionEngine
//  or a local spy. Covers acceptance criteria 1–6.
//

@testable import Bonk
import Foundation
import Testing

// MARK: - Spy engine (proves when the engine is / isn't consulted)

actor SpyDecisionEngine: DecisionEngine {
    let engineName = "spy"
    let choiceConfidenceSource = "spy"
    private(set) var chooseCalls = 0
    var forcedSelection: String?

    func choose(options: [DecisionOption], context _: DecisionContext) async throws -> ChoiceDecision {
        chooseCalls += 1
        let selection = forcedSelection ?? options.first?.id
        return ChoiceDecision(selectedID: selection, confidence: 0.9, rationale: .modelJudgment("spy"))
    }

    func gate(question _: String, context _: DecisionContext) async throws -> GateDecision {
        GateDecision(shouldProceed: true, confidence: 0.9)
    }

    func score(option: DecisionOption, context _: DecisionContext) async throws -> ScoreDecision {
        ScoreDecision(score: option.localScore, confidence: 0.9)
    }
}

@MainActor
struct DecisionEngineContractTests {
    private func router() -> ModelRouter {
        ModelRouter(store: AIProviderStore())
    }

    private func ollama() -> AIProviderConfig {
        AIProviderConfig(name: "local", type: .ollama, model: "llama3")
    }

    private func openAI() -> AIProviderConfig {
        AIProviderConfig(name: "cloud", type: .openAI, model: "gpt-5.6-terra")
    }

    private func inlineContext(budgetMs: Int = 3000) -> RouterContext {
        RouterContext(task: .inlineCompletion, contextSize: 10, latencyBudgetMs: budgetMs)
    }

    // MARK: - Criterion 1: single provider never consults the engine

    @Test("1. Single surviving provider returns without calling DecisionEngine")
    func testSingleProviderNeverCallsEngine() async throws {
        let spy = SpyDecisionEngine()
        let routed = await router().route(
            task: .agentExecute,
            providers: [ollama(), openAI()],
            context: RouterContext(task: .agentExecute, contextSize: 10, latencyBudgetMs: 15000),
            decisionEngine: spy
        )
        // ollama lacks tool calls → filtered before the engine ever sees
        // candidates. The rogue forced selection can never take effect:
        // the engine is not even consulted for a single survivor.
        #expect(routed?.provider.type == .openAI)
        #expect(routed?.source == .deterministicSingle)
        #expect(await spy.chooseCalls == 0)
    }

    @Test("2c. Engine returning an unknown ID falls back to deterministic rank")
    func testUnknownEngineSelectionFallsBack() async throws {
        let spy = SpyDecisionEngine()
        await spy.setForcedSelection(UUID().uuidString) // Not among the options.
        let routed = await router().route(
            task: .inlineCompletion,
            providers: [ollama(), openAI()],
            context: inlineContext(),
            decisionEngine: spy
        )
        #expect(await spy.chooseCalls == 1)
        #expect(routed?.provider.type == .ollama) // Deterministic top rank.
        #expect(routed?.source == .deterministicRanked)
    }

    // MARK: - Criterion 2: hard constraints can never be overridden by a model

    @Test("2. Engine cannot resurrect a provider killed by hard filters")
    func testEngineCannotOverrideHardFilters() async throws {
        let ollamaID = UUID()
        var local = ollama()
        local = AIProviderConfig(id: ollamaID, name: "local", type: .ollama, model: "llama3")
        let spy = SpyDecisionEngine()
        await spy.setForcedSelection(ollamaID.uuidString) // Rogue: pick the filtered-out one.

        let routed = await router().route(
            task: .agentExecute, // Requires tool calls; ollama is out.
            providers: [local, openAI()],
            context: RouterContext(task: .agentExecute, contextSize: 10, latencyBudgetMs: 15000),
            decisionEngine: spy
        )
        // Only openAI reaches the engine, so the rogue selection matches
        // nothing and routing falls back to the deterministic top rank.
        // (Single survivor: the engine is not consulted at all.)
        #expect(routed?.provider.type == .openAI)
        #expect(routed?.source == .deterministicSingle)
        #expect(await spy.chooseCalls == 0)
    }

    @Test("2b. Latency and cost filters exclude before any engine sees candidates")
    func testLatencyAndCostFilters() {
        let router = router()
        let all = [ollama(), openAI()]
        // Tight budget: cloud estimate (2500ms) exceeds it, local passes.
        let tight = router.filter(task: .inlineCompletion, providers: all, context: inlineContext(budgetMs: 1500))
        #expect(tight.map(\.type) == [.ollama])
        // Free-only policy drops metered providers regardless of rank.
        let free = router.filter(
            task: .inlineCompletion, providers: all,
            context: RouterContext(
                task: .inlineCompletion, contextSize: 10,
                latencyBudgetMs: 3000, costPolicy: .freeOnly
            )
        )
        #expect(free.map(\.type) == [.ollama])
    }

    // MARK: - Criterion 3: exact-prefix local path short-circuits

    @Test("3. Exact match wins in DeterministicDecisionEngine regardless of score")
    func testExactMatchShortCircuits() async throws {
        let engine = DeterministicDecisionEngine()
        let options = [
            DecisionOption(id: "history", localScore: 99.0),
            DecisionOption(id: "exact", localScore: 10.0, isExactMatch: true),
        ]
        let decision = try await engine.choose(
            options: options,
            context: DecisionContext(localConfidence: 1.0)
        )
        #expect(decision.selectedID == "exact")
        #expect(decision.rationale == .exactMatch)
    }

    @Test("3b. Gate follows local confidence against the threshold")
    func testGateFollowsThreshold() async throws {
        let engine = DeterministicDecisionEngine()
        let open = try await engine.gate(question: "show?", context: DecisionContext(localConfidence: 0.9))
        #expect(open.shouldProceed)
        let closed = try await engine.gate(question: "show?", context: DecisionContext(localConfidence: 0.2))
        #expect(!closed.shouldProceed)
    }

    // MARK: - Criterion 4: engine runs only in the uncertainty interval

    @Test("4. Engine is consulted only when N > 1 survives filtering")
    func testEngineOnlyInUncertaintyInterval() async throws {
        let spy = SpyDecisionEngine()
        let routed = await router().route(
            task: .inlineCompletion,
            providers: [ollama(), openAI()],
            context: inlineContext(),
            decisionEngine: spy
        )
        #expect(await spy.chooseCalls == 1)
        #expect(routed?.source == .decisionEngine)
    }

    // MARK: - Criterion 5: engine is fully swappable with the deterministic one

    @Test("5. DeterministicDecisionEngine is a drop-in route engine")
    func testDeterministicEngineSwappable() async throws {
        let first = await router().route(
            task: .inlineCompletion,
            providers: [ollama(), openAI()],
            context: inlineContext(),
            decisionEngine: DeterministicDecisionEngine()
        )
        let second = await router().route(
            task: .inlineCompletion,
            providers: [openAI(), ollama()], // Input order must not matter.
            context: inlineContext(),
            decisionEngine: DeterministicDecisionEngine()
        )
        #expect(first?.provider.type == second?.provider.type)
        #expect(first?.source == .decisionEngine)
    }

    // MARK: - Criterion 6: no model, no regression

    @Test("6. Nil engine routes deterministically with zero behavior change")
    func testNilEngineNoRegression() async throws {
        let routed = await router().route(
            task: .inlineCompletion,
            providers: [ollama(), openAI()],
            context: inlineContext(),
            preferredID: nil,
            decisionEngine: nil
        )
        // Free + local-first ranking: ollama outranks cloud without preference.
        #expect(routed?.provider.type == .ollama)
        #expect(routed?.source == .deterministicRanked)
    }

    @Test("6b. Preferred (active) provider keeps priority when it passes filters")
    func testPreferredProviderKeepsPriority() async throws {
        let cloud = openAI()
        let routed = await router().route(
            task: .inlineCompletion,
            providers: [ollama(), cloud],
            context: inlineContext(),
            preferredID: cloud.id,
            decisionEngine: nil
        )
        #expect(routed?.provider.id == cloud.id)
    }
}

extension SpyDecisionEngine {
    func setForcedSelection(_ id: String) {
        forcedSelection = id
    }
}
