//
//  OutputTokenBudget.swift
//  Bonk
//
//  The output token budget for one model turn.
//
//  Every path that asks a model to produce text resolves its budget here.
//  The codebase used to carry five different defaults for the same decision
//  — 500, 2000 and 4096 — scattered across adapters and networking
//  helpers, so the same model in the same conversation was answered within
//  a different budget depending on which path it took:
//
//      Claude, Ask mode            500
//      Claude, agent tool loop    4096
//      OpenAI, chat               4096
//      OpenAI, agent tool loop    2000
//      OpenAI Responses, chat      500
//      OpenAI Responses, tool loop 2000
//
//  500 tokens is roughly 350 words: a long answer was cut mid-sentence, and
//  the path that does the most work per turn — the agent loop, which spends
//  its budget on a tool call and the reasoning around it — had the smallest
//  budget of all. The tool loop and the chat path are not different kinds
//  of question, so they are not different kinds of budget.
//

import Foundation

enum OutputTokenBudget {

    /// The budget used when neither the user nor the provider says otherwise.
    ///
    /// Matches the longest-standing chat default. Generous enough for a full
    /// answer, and inside every provider's limit, so the budget is never the
    /// reason a turn fails.
    static let fallback = 4_096

    /// Claude models comfortably allow more than the fallback, and a Claude
    /// answer is the one people tend to want in full.
    static let claude = 8_192

    /// The default for a provider type, when it has one.
    static func declaredDefault(for type: AIProviderType) -> Int? {
        switch type {
        case .claude: claude
        default: nil
        }
    }

    /// Resolve the budget for one turn.
    ///
    /// An explicit setting is the user's decision and is used as given: the
    /// provider is the authority on whether a model accepts it, and a value
    /// the provider rejects says more than a silent clamp would. Without
    /// one, the provider's declared default applies, and the fallback is
    /// the last resort.
    ///
    /// The per-call argument wins over the provider's saved setting, because
    /// it is the more specific instruction.
    static func resolve(
        requested: Int?,
        providerType: AIProviderType
    ) -> Int {
        if let requested, requested > 0 { return requested }
        return declaredDefault(for: providerType) ?? fallback
    }

    /// Resolve from the two sources a provider holds: a per-call request
    /// and the provider's saved setting.
    static func resolve(
        perCall: Int?,
        saved: Int?,
        providerType: AIProviderType
    ) -> Int {
        resolve(requested: perCall ?? saved, providerType: providerType)
    }
}
