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
    private var currentEffectiveKey: String?

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
        currentEffectiveKey = nil
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
        guard let s = suggestion else { return }
        let key = currentEffectiveKey ?? currentKey
        guard let k = key else { return }
        cache.markRejected(suffix: s.text, for: k)
        cancel()
    }

    // MARK: - Pipeline

    private func perform(snapshot: CommandContextSnapshot, typed: String, generation: UInt64) async {
        guard generationController.isCurrent(generation) else { return }

        // Resolve cache key for provider-aware caching; fallback to local key when no provider for rejection tracking
        let provider = providerStore.activeProvider
        let key: String? = provider.map { InlineSuggestionCache.cacheKey(provider: $0, snapshot: snapshot, typed: typed) }
        let effectiveKey = key ?? "local|\(snapshot.hostKey ?? "")|\(typed)"
        currentKey = key
        currentEffectiveKey = effectiveKey

        // 1. KnownWords instant
        if let sug = await knownWordsSource.suggestion(for: snapshot, typed: typed),
           !cache.isRejected(key: effectiveKey, suffix: sug.text) {
            commit(sug, key: key, generation: generation, effectiveKey: effectiveKey)
        }

        // 2. Cache hit (memory/persistent) — instant repeat (only when provider key exists)
        if let k = key, let cached = cache.cachedSuffix(for: k), !cache.isRejected(key: k, suffix: cached) {
            let display = SuggestionFormatter.displaySuffix(cached, typed: typed)
            let sug = Suggestion(text: cached, displayText: display)
            commit(sug, key: k, generation: generation, effectiveKey: effectiveKey)
        }

        // 3. History instant
        if let sug = await historySource.suggestion(for: snapshot, typed: typed),
           !cache.isRejected(key: effectiveKey, suffix: sug.text) {
            commit(sug, key: key, generation: generation, effectiveKey: effectiveKey)
        }

        // 4. LLM (async streaming, may replace local with smarter)
        guard let k = key else {
            isRequesting = false
            return
        }
        isRequesting = true
        generationController.runWork { [weak self] in
            guard let self else { return }
            defer { if self.generationController.isCurrent(generation) { self.isRequesting = false } }
            await self.llmSource.stream(for: snapshot, typed: typed, generation: generation, cacheKey: k) { text in
                guard self.generationController.isCurrent(generation) else { return }
                let sug = Suggestion(text: text, displayText: text)
                self.commit(sug, key: k, generation: generation, effectiveKey: effectiveKey)
            }
        }
    }

    private func commit(_ sug: Suggestion, key: String?, generation: UInt64, effectiveKey: String? = nil) {
        guard generationController.isCurrent(generation) else { return }
        suggestion = sug
        currentKey = key
        if let ek = effectiveKey { currentEffectiveKey = ek }
        if let k = key, !sug.text.isEmpty { cache.store(suffix: sug.text, for: k) }
        // Also store under effectiveKey for local rejection tracking when no provider
        if let ek = effectiveKey, key == nil, !sug.text.isEmpty { cache.store(suffix: sug.text, for: ek) }
    }
}
