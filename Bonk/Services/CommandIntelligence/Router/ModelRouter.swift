//  ModelRouter.swift
//  Bonk — Provider selection by Task+Capability+Latency+ContextSize+Cost (Invariant #8)
//  Experience→Intelligence→Router→Provider.
//
//  Phase 1: deterministic routing only. Hard filters (capability, latency,
//  cost) narrow providers to 1…N; deterministic ranking orders them. A
//  DecisionEngine is consulted ONLY when N > 1 with genuine semantic choice
//  space — and the single-provider hot path never touches it.

import Foundation

enum IntelligenceTask: Sendable {
    case inlineCompletion
    case chat
    case agentPlan
    case agentExecute
}

/// Cost constraint for routing. Phase 1 tiers are coarse by design:
/// local/keyless providers are free, everything else is metered.
enum RoutingCostPolicy: Sendable {
    case any
    case freeOnly
}

struct RouterContext: Sendable {
    let task: IntelligenceTask
    let contextSize: Int // tokens/chars
    let latencyBudgetMs: Int
    let requiresCapability: String? // e.g., "streaming", "toolCalls"
    let costPolicy: RoutingCostPolicy

    init(
        task: IntelligenceTask,
        contextSize: Int,
        latencyBudgetMs: Int,
        requiresCapability: String? = nil,
        costPolicy: RoutingCostPolicy = .any
    ) {
        self.task = task
        self.contextSize = contextSize
        self.latencyBudgetMs = latencyBudgetMs
        self.requiresCapability = requiresCapability
        self.costPolicy = costPolicy
    }
}

/// Where a routing decision came from. Observable so tests (and telemetry)
/// can prove the DecisionEngine only runs in the uncertainty interval.
enum RoutingSource: Sendable, Equatable {
    /// Exactly one provider survived the filters.
    case deterministicSingle
    /// N > 1 but no engine supplied (or engine failed): top-ranked wins.
    case deterministicRanked
    /// N > 1 and the engine made the semantic choice.
    case decisionEngine
}

struct RoutedProvider: Sendable {
    let provider: AIProviderConfig
    let source: RoutingSource
}

final class ModelRouter: @unchecked Sendable {
    static let shared: ModelRouter = {
        MainActor.assumeIsolated { ModelRouter(store: AIProviderStore.shared) }
    }()
    private let store: AIProviderStore

    init(store: AIProviderStore) { self.store = store }

    // MARK: - Legacy entry points (behavior-preserving, deterministic only)

    @MainActor func provider(for ctx: RouterContext) -> AIProviderConfig? {
        routeDeterministic(
            task: ctx.task,
            providers: store.providers,
            context: ctx,
            preferredID: store.activeProvider?.id
        )?.provider
    }

    @MainActor func provider(for task: IntelligenceTask, snapshot: CommandContextSnapshot) -> AIProviderConfig? {
        let ctx = RouterContext(
            task: task,
            contextSize: snapshot.inputBuffer.count + snapshot.recentOutput.count,
            latencyBudgetMs: task == IntelligenceTask.inlineCompletion ? 3000 : 15000,
            requiresCapability: nil
        )
        return provider(for: ctx)
    }

    // MARK: - Phase-1 route

    /// Full route. The engine is optional and runs only when filtering +
    /// ranking leave genuine ambiguity (N > 1). Engine failure falls back
    /// to the deterministic top rank — routing never fails open to nil
    /// when a filtered provider exists.
    func route(
        task: IntelligenceTask,
        providers: [AIProviderConfig],
        context: RouterContext,
        preferredID: UUID? = nil,
        decisionEngine: (any DecisionEngine)? = nil
    ) async -> RoutedProvider? {
        let ranked = rank(
            task: task,
            providers: filter(task: task, providers: providers, context: context),
            context: context,
            preferredID: preferredID
        )
        guard !ranked.isEmpty else { return nil }
        guard ranked.count > 1 else {
            return RoutedProvider(provider: ranked[0], source: .deterministicSingle)
        }
        guard let engine = decisionEngine else {
            return RoutedProvider(provider: ranked[0], source: .deterministicRanked)
        }
        let options = ranked.map {
            DecisionOption(id: $0.id.uuidString, localScore: rankScore(for: $0, preferredID: preferredID))
        }
        do {
            let decision = try await engine.choose(
                options: options,
                context: DecisionContext(localConfidence: 0, decisionThreshold: 1.0)
            )
            if let id = decision.selectedID,
               let chosen = ranked.first(where: { $0.id.uuidString == id }) {
                return RoutedProvider(provider: chosen, source: .decisionEngine)
            }
        } catch {
            // Fall through to deterministic top rank.
        }
        return RoutedProvider(provider: ranked[0], source: .deterministicRanked)
    }

    /// Synchronous deterministic core: filters + ranking, no engine.
    /// Legacy callers and the hot path use this.
    func routeDeterministic(
        task: IntelligenceTask,
        providers: [AIProviderConfig],
        context: RouterContext,
        preferredID: UUID? = nil
    ) -> RoutedProvider? {
        let ranked = rank(
            task: task,
            providers: filter(task: task, providers: providers, context: context),
            context: context,
            preferredID: preferredID
        )
        guard !ranked.isEmpty else { return nil }
        return RoutedProvider(
            provider: ranked[0],
            source: ranked.count > 1 ? .deterministicRanked : .deterministicSingle
        )
    }

    // MARK: - Hard filters (a model can never override these)

    func filter(task: IntelligenceTask, providers: [AIProviderConfig], context: RouterContext) -> [AIProviderConfig] {
        providers.filter { provider in
            capabilityAllows(task: task, provider: provider, context: context)
                && latencyAllows(provider: provider, budgetMs: context.latencyBudgetMs)
                && costAllows(provider: provider, policy: context.costPolicy)
        }
    }

    private func capabilityAllows(task: IntelligenceTask, provider: AIProviderConfig, context: RouterContext) -> Bool {
        let capability = AIProviderCapabilityResolver.resolve(
            config: provider, workload: workload(for: task)
        ).capability
        if let required = context.requiresCapability {
            switch required {
            case "streaming": return capability.supportsStreaming
            case "toolCalls": return capability.supportsToolCalls
            default: break // Unknown requirement names fall back to task default.
            }
        }
        switch task {
        case .inlineCompletion:
            return capability.supportsStreaming
        case .chat, .agentPlan:
            return capability.supportsChatCompletions || capability.supportsResponses
        case .agentExecute:
            return capability.supportsToolCalls
        }
    }

    private func workload(for task: IntelligenceTask) -> AIWorkload {
        switch task {
        case .inlineCompletion: return .inlineCompletion
        case .chat, .agentPlan: return .chat
        case .agentExecute: return .agentToolLoop
        }
    }

    /// Static latency estimates (ms) per provider type. Explicit defaults,
    /// pending measured telemetry — ranking input only, never a promise.
    func estimatedLatencyMs(for provider: AIProviderConfig) -> Int {
        switch provider.type {
        case .ollama: return 1200 // Local inference, no network round-trip.
        default: return 2500 // Cloud round-trip default.
        }
    }

    private func latencyAllows(provider: AIProviderConfig, budgetMs: Int) -> Bool {
        estimatedLatencyMs(for: provider) <= budgetMs
    }

    private func costAllows(provider: AIProviderConfig, policy: RoutingCostPolicy) -> Bool {
        switch policy {
        case .any: return true
        case .freeOnly: return !provider.type.needsAPIKey
        }
    }

    // MARK: - Deterministic ranking

    /// Rank score: preferred (active) provider first, then free over metered,
    /// then lower estimated latency. Stable and total.
    func rankScore(for provider: AIProviderConfig, preferredID: UUID? = nil) -> Double {
        var score = 0.0
        if provider.id == preferredID { score += 10_000 }
        if !provider.type.needsAPIKey { score += 1_000 }
        score -= Double(estimatedLatencyMs(for: provider))
        return score
    }

    private func rank(
        task _: IntelligenceTask,
        providers: [AIProviderConfig],
        context _: RouterContext,
        preferredID: UUID?
    ) -> [AIProviderConfig] {
        providers.sorted { rankScore(for: $0, preferredID: preferredID) > rankScore(for: $1, preferredID: preferredID) }
    }
}
