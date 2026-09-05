//  ModelRouter.swift
//  Bonk — Provider selection by Task+Capability+Latency+ContextSize+Cost (Invariant #8)
//  Experience→Intelligence→Router→Provider. P0 stub: picks activeProvider, future scores.

import Foundation

enum IntelligenceTask: Sendable {
    case inlineCompletion
    case chat
    case agentPlan
    case agentExecute
}

struct RouterContext: Sendable {
    let task: IntelligenceTask
    let contextSize: Int // tokens/chars
    let latencyBudgetMs: Int
    let requiresCapability: String? // e.g., "code", "reasoning"
}

final class ModelRouter: @unchecked Sendable {
    static let shared: ModelRouter = {
        MainActor.assumeIsolated { ModelRouter(store: AIProviderStore.shared) }
    }()
    private let store: AIProviderStore

    init(store: AIProviderStore) { self.store = store }

    @MainActor func provider(for ctx: RouterContext) -> AIProviderConfig? {
        let active = store.activeProvider
        guard let active else { return nil }
        return active
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
}
