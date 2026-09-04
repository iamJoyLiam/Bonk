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
    var isRequesting = false
    /// Ranked candidate list, best first. The ghost shows the selected entry;
    /// count > 1 renders the Warp-style ↑/↓ popup above the cursor.
    private(set) var ranked: [(String, Suggestion)] = []
    private var selectedIndex = 0
    /// Selected suggestion (ghost text) — computed from ranked + selectedIndex.
    var suggestion: Suggestion? {
        guard !ranked.isEmpty else { return nil }
        let index = max(0, min(selectedIndex, ranked.count - 1))
        return ranked[index].1
    }
    /// View callback for ghost updates — pipeline remains UI-agnostic, View subscribes.
    var onSuggestionChanged: ((Suggestion?) -> Void)?
    var onRequestingChanged: ((Bool) -> Void)?
    /// Candidate list changed: (count, selectedIndex). Count <= 1 hides the popup.
    var onCandidatesChanged: ((Int, Int) -> Void)?

    private let logger = Logger(subsystem: "com.bonk", category: "InlinePipeline")
    private let generationController = GenerationController()
    private let cache: InlineSuggestionCache
    private let ranker = InlineRanker()
    private let providerStore: AIProviderStore

    private let knownWordsSource = KnownWordsCandidateSource()
    private let historySource = HistoryCandidateSource()
    private let vocabularySource = CommandVocabularySource()
    private let llmSource: LLMCandidateSource

    /// Cap for the candidate popup — best-ranked entries survive.
    private static let maxCandidates = 5

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
        // Tier 1: deterministic local candidates (knownWords/cache/history) —
        // instant, no debounce. Warp-style: local ghost appears immediately.
        performLocal(snapshot: snapshot, typed: typed, generation: gen)
        // Tier 2: LLM — debounced so streaming never fights typing/Tab.
        generationController.scheduleDebounced { [weak self] in
            await self?.performLLM(snapshot: snapshot, typed: typed, generation: gen)
        }
    }

    func cancel() {
        generationController.cancelAll()
        ranked = []
        selectedIndex = 0
        onSuggestionChanged?(nil)
        onCandidatesChanged?(0, 0)
        currentKey = nil
        currentEffectiveKey = nil
        isRequesting = false
        onRequestingChanged?(false)
    }

    /// Move the candidate selection (↑/↓ in the popup). Clamps at the ends.
    func moveSelection(_ delta: Int) {
        guard ranked.count > 1 else { return }
        let newIndex = max(0, min(ranked.count - 1, selectedIndex + delta))
        guard newIndex != selectedIndex else { return }
        selectedIndex = newIndex
        onSuggestionChanged?(suggestion)
        onCandidatesChanged?(ranked.count, selectedIndex)
    }

    func accept() -> String {
        guard let s = suggestion else { return "" }
        if let key = currentKey { cache.markAccepted(for: key) }
        UserProfile.shared.recordAccept(suffix: s.text)
        let text = s.text
        cancel()
        return text
    }

    func rejectCurrent() {
        guard let s = suggestion else { return }
        let key = currentEffectiveKey ?? currentKey
        guard let k = key else { return }
        cache.markRejected(suffix: s.text, for: k)
        UserProfile.shared.recordReject(suffix: s.text)
        cancel()
    }

    // MARK: - Pipeline

    private func performLocal(snapshot: CommandContextSnapshot, typed: String, generation: UInt64) {
        guard generationController.isCurrent(generation) else { return }

        // Resolve cache key for provider-aware caching; fallback to local key when no provider for rejection tracking
        let provider = providerStore.activeProvider
        let key: String? = provider.map { InlineSuggestionCache.cacheKey(provider: $0, snapshot: snapshot, typed: typed) }
        let effectiveKey = key ?? "local|\(snapshot.hostKey ?? "")|\(typed)"
        currentKey = key
        currentEffectiveKey = effectiveKey

        var candidates: [(String, Suggestion)] = []
        if let sug = knownWordsSource.syncSuggestion(for: snapshot, typed: typed) {
            candidates.append((knownWordsSource.name, sug))
        }
        if let k = key, let cached = cache.cachedSuffix(for: k) {
            let display = SuggestionFormatter.displaySuffix(cached, typed: typed)
            let sug = Suggestion(text: cached, displayText: display)
            candidates.append(("cache", sug))
        }
        if let sug = historySource.syncSuggestion(for: snapshot, typed: typed) {
            candidates.append((historySource.name, sug))
        }
        if let sug = vocabularySource.syncSuggestion(for: snapshot, typed: typed) {
            candidates.append((vocabularySource.name, sug))
        }

        let isRejected: (String) -> Bool = { [self] suffix in
            cache.isRejected(key: effectiveKey, suffix: suffix)
                || (key != nil && cache.isRejected(key: key!, suffix: suffix))
        }
        let withFullCommand = candidates.map { ($0.0, $0.1.withFullCommand(typed: typed)) }
        setRanked(ranker.sortedCandidates(in: withFullCommand, isRejected: isRejected), generation: generation)

        // Cache the top local candidate for parity with previous commit behavior.
        if let k = key, let first = ranked.first, !first.1.text.isEmpty {
            cache.store(suffix: first.1.text, for: k)
        }
        if key == nil, let first = ranked.first, !first.1.text.isEmpty {
            cache.store(suffix: first.1.text, for: effectiveKey)
        }
    }

    private func performLLM(snapshot: CommandContextSnapshot, typed: String, generation: UInt64) async {
        guard generationController.isCurrent(generation) else { return }

        let key: String? = currentKey ?? providerStore.activeProvider.map {
            InlineSuggestionCache.cacheKey(provider: $0, snapshot: snapshot, typed: typed)
        }
        let effectiveKey = currentEffectiveKey ?? (key ?? "local|\(snapshot.hostKey ?? "")|\(typed)")

        // LLM (async streaming, may replace local with smarter)
        guard let k = key else {
            isRequesting = false
            onRequestingChanged?(false)
            return
        }
        isRequesting = true
        onRequestingChanged?(true)
        generationController.runWork { [weak self] in
            guard let self else { return }
            defer {
                if self.generationController.isCurrent(generation) {
                    self.isRequesting = false
                    self.onRequestingChanged?(false)
                }
            }
            await self.llmSource.stream(for: snapshot, typed: typed, generation: generation, cacheKey: k) { text in
                guard self.generationController.isCurrent(generation) else { return }
                let sug = Suggestion(text: text, displayText: text).withFullCommand(typed: typed)
                self.commitLLM(sug, key: k, generation: generation, effectiveKey: effectiveKey)
            }
        }
    }

    /// Replace the pipeline candidate list (local tier).
    private func setRanked(_ list: [(String, Suggestion)], generation: UInt64) {
        guard generationController.isCurrent(generation) else { return }
        var seen = Set<String>()
        ranked = Array(list.filter { seen.insert($0.1.text).inserted }.prefix(Self.maxCandidates))
        selectedIndex = 0
        onSuggestionChanged?(suggestion)
        onCandidatesChanged?(ranked.count, selectedIndex)
    }

    /// LLM stream commit — inserts at the top (replacing any previous LLM entry),
    /// local candidates stay accessible via ↓, matching previous override semantics.
    private func commitLLM(_ sug: Suggestion, key: String?, generation: UInt64, effectiveKey: String) {
        guard generationController.isCurrent(generation) else { return }
        let remaining = ranked.filter { $0.0 != llmSource.name && $0.1.text != sug.text }
        ranked = Array(([(llmSource.name, sug)] + remaining).prefix(Self.maxCandidates))
        selectedIndex = 0
        if let k = key, !sug.text.isEmpty { cache.store(suffix: sug.text, for: k) }
        if key == nil, !sug.text.isEmpty { cache.store(suffix: sug.text, for: effectiveKey) }
        onSuggestionChanged?(suggestion)
        onCandidatesChanged?(ranked.count, selectedIndex)
    }
}
