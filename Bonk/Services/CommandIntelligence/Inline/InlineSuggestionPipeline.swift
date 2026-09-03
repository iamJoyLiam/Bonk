//  InlineSuggestionPipeline.swift
//  Bonk
//
//  Single orchestration: Local → Context → LLM → Ranker → Generation-safe Commit
//  Replaces dual orchestration (SuggestionEngine + InlineCompletionService).
//  P0: scaffolding — local/history/knownWords sync path + generation guard; LLM stubbed.
//

import Combine
import Foundation
import SwiftData
import os

@MainActor
@Observable
final class InlineSuggestionPipeline {
    var suggestion: Suggestion?
    var isRequesting = false

    private let logger = Logger(subsystem: "com.bonk", category: "InlinePipeline")
    private let generationController = GenerationController()
    private let cache: InlineSuggestionCache
    private let ranker = InlineRanker()
    private let providerStore: AIProviderStore

    private let knownWordsSource = KnownWordsCandidateSource()
    private let historySource = HistoryCandidateSource()
    private let llmSource: LLMCandidateSource

    private var currentKey: String?

    init(
        providerStore: AIProviderStore = .shared,
        cache: InlineSuggestionCache = InlineSuggestionCache()
    ) {
        self.providerStore = providerStore
        self.cache = cache
        self.llmSource = LLMCandidateSource(providerStore: providerStore, cache: cache)
    }

    func attachModelContext(_ ctx: SwiftData.ModelContext) {
        cache.attachModelContext(ctx)
    }

    // MARK: - Public

    func request(snapshot: CommandContextSnapshot) {
        let typed = snapshot.inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else {
            cancel()
            return
        }
        let gen = generationController.bumpGeneration()
        generationController.scheduleDebounced { [weak self] in
            await self?.perform(snapshot: snapshot, typed: typed, generation: gen)
        }
    }

    func cancel() {
        generationController.cancelAll()
        suggestion = nil
        currentKey = nil
        isRequesting = false
    }

    func accept() -> String {
        guard let s = suggestion else { return "" }
        if let key = currentKey { cache.markAccepted(for: key) }
        let text = s.text
        cancel()
        return text
    }

    func rejectCurrent() {
        guard let s = suggestion, let key = currentKey else { return }
        cache.markRejected(suffix: s.text, for: key)
        cancel()
    }

    // MARK: - Pipeline

    private func perform(snapshot: CommandContextSnapshot, typed: String, generation: UInt64) async {
        guard generationController.isCurrent(generation) else { return }

        // Resolve cache key for provider-aware caching
        let provider = providerStore.activeProvider
        let key: String? = provider.map { InlineSuggestionCache.cacheKey(provider: $0, snapshot: snapshot, typed: typed) }
        currentKey = key

        // 1. KnownWords instant
        if let sug = await knownWordsSource.suggestion(for: snapshot, typed: typed),
           !(key.map { cache.isRejected(key: $0, suffix: sug.text) } ?? false) {
            commit(sug, key: key, generation: generation)
        }

        // 2. Cache hit (memory/persistent) — instant repeat
        if let k = key, let cached = cache.cachedSuffix(for: k), !cache.isRejected(key: k, suffix: cached) {
            let display = SuggestionFormatter.displaySuffix(cached, typed: typed)
            let sug = Suggestion(text: cached, displayText: display)
            commit(sug, key: k, generation: generation)
        }

        // 3. History instant
        if let sug = await historySource.suggestion(for: snapshot, typed: typed),
           !(key.map { cache.isRejected(key: $0, suffix: sug.text) } ?? false) {
            commit(sug, key: key, generation: generation)
        }

        // 4. LLM (async, may replace local with smarter)
        // P0: stubbed — full streaming will be moved from InlineCompletionService in next phase
        isRequesting = true
        generationController.runWork { [weak self] in
            guard let self else { return }
            defer { if self.generationController.isCurrent(generation) { self.isRequesting = false } }
            if let llmSug = await self.llmSource.suggestion(for: snapshot, typed: typed) {
                guard self.generationController.isCurrent(generation) else { return }
                if let k = key, self.cache.isRejected(key: k, suffix: llmSug.text) { return }
                self.commit(llmSug, key: key, generation: generation)
                if let k = key { self.cache.store(suffix: llmSug.text, for: k) }
            }
        }
    }

    private func commit(_ sug: Suggestion, key: String?, generation: UInt64) {
        guard generationController.isCurrent(generation) else { return }
        suggestion = sug
        currentKey = key
        if let k = key, !sug.text.isEmpty { cache.store(suffix: sug.text, for: k) }
    }
}
