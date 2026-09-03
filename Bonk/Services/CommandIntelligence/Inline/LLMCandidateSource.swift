//  LLMCandidateSource.swift
//  Bonk
//
//  LLM as one CandidateSource — not a serial stage.
//  Wraps LLMProviderFactory + prompt + streaming + timeout + normalize.
//  P0: scaffolding delegates to InlineCompletionService's proven streaming for parity, but via protocol.
//

import Foundation

final class LLMCandidateSource: InlineCandidateSource, @unchecked Sendable {
    let name = "llm"
    private let providerStore: AIProviderStore
    private let cache: InlineSuggestionCache?
    private let maxTokens = InlineCompletionService.maxSuggestionTokens
    private let maxChars = InlineCompletionService.maxSuggestionChars

    @MainActor init(providerStore: AIProviderStore, cache: InlineSuggestionCache? = nil) {
        self.providerStore = providerStore
        self.cache = cache
    }

    func suggestion(for snapshot: CommandContextSnapshot, typed: String) async -> Suggestion? {
        // Check provider resolution — fail gracefully, don't block other sources
        guard let provider = await MainActor.run(body: { self.providerStore.activeProvider }) else { return nil }
        let prompt = await MainActor.run { InlinePromptBuilder.buildPrompt(snapshot: snapshot) }
        // For P0 scaffolding, we do not yet stream; single attempt via factory.
        // Full streaming will be moved from InlineCompletionService.streamModelSuggestion.
        // Return nil for now — pipeline will treat LLM as async and handle progressive replace separately.
        _ = prompt
        _ = provider
        return nil
    }

    // MARK: - Helpers (delegated for parity)

    func normalize(_ raw: String) -> String {
        SuggestionFormatter.normalize(raw)
    }

    func displaySuffix(_ suffix: String, typed: String) -> String {
        SuggestionFormatter.displaySuffix(suffix, typed: typed)
    }
}
