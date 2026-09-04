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
    private var currentCandidates: [CommandCandidate] = []
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

        // Tier 2: Evaluate TriggerPolicy before scheduling LLM
        let confidence = evaluateConfidence(for: currentCandidates, typed: typed)
        let decision = InlineTriggerPolicy.evaluate(
            typed: typed,
            snapshot: snapshot,
            confidence: confidence
        )
        guard decision.shouldRequestLLM else {
            logger.debug("Inline LLM skipped by policy: \(decision.reason.rawValue)")
            return
        }

        // Tier 2: LLM — debounced by policy delay so streaming never fights typing/Tab.
        generationController.scheduleDebounced(delayMs: decision.debounceMs) { [weak self] in
            await self?.performLLM(snapshot: snapshot, typed: typed, generation: gen)
        }
    }

    private func evaluateConfidence(for candidates: [CommandCandidate], typed: String) -> DeterministicConfidence {
        guard let top = candidates.first else {
            return .low
        }
        if top.authority == .deterministic {
            if top.rawScore >= 75.0 || top.isExactPrefixMatch {
                return .high(candidate: top.suggestion)
            }
            return .medium(candidates: candidates.map(\.suggestion))
        }
        return .low
    }

    func cancel() {
        generationController.cancelAll()
        currentCandidates = []
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

        let isRejected: (String) -> Bool = { [self] suffix in
            cache.isRejected(key: effectiveKey, suffix: suffix)
                || (key != nil && cache.isRejected(key: key!, suffix: suffix))
        }

        var localCandidates: [CommandCandidate] = []
        func appendLocal(source: String, sug: Suggestion) {
            let full = sug.withFullCommand(typed: typed)
            let sc = ranker.score(suggestion: full, source: source)
            localCandidates.append(CommandCandidate(
                source: source,
                authority: .deterministic,
                suggestion: full,
                rawScore: sc
            ))
        }

        if let sug = knownWordsSource.syncSuggestion(for: snapshot, typed: typed) {
            appendLocal(source: knownWordsSource.name, sug: sug)
        }
        if let k = key, let cached = cache.cachedSuffix(for: k) {
            let display = SuggestionFormatter.displaySuffix(cached, typed: typed)
            let sug = Suggestion(text: cached, displayText: display)
            appendLocal(source: "cache", sug: sug)
        }
        if let sug = historySource.syncSuggestion(for: snapshot, typed: typed) {
            appendLocal(source: historySource.name, sug: sug)
        }
        if let sug = vocabularySource.syncSuggestion(for: snapshot, typed: typed) {
            appendLocal(source: vocabularySource.name, sug: sug)
        }

        let rankedList = CandidateRanker.rank(candidates: localCandidates, isRejected: isRejected)
        setRankedCandidates(rankedList, generation: generation)

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

        // LLM (async streaming, evaluated via CandidateRanker alongside local candidates)
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

    /// Replace the pipeline candidate list using ranked CommandCandidates.
    private func setRankedCandidates(_ list: [CommandCandidate], generation: UInt64) {
        guard generationController.isCurrent(generation) else { return }
        currentCandidates = list
        ranked = Array(list.map { ($0.source, $0.suggestion) }.prefix(Self.maxCandidates))
        selectedIndex = 0
        onSuggestionChanged?(suggestion)
        onCandidatesChanged?(ranked.count, selectedIndex)
    }

    /// LLM stream commit — routes through CandidateRanker without force-promoting above deterministic candidates.
    private func commitLLM(_ sug: Suggestion, key: String?, generation: UInt64, effectiveKey: String) {
        guard generationController.isCurrent(generation) else { return }
        let isRejected: (String) -> Bool = { [self] suffix in
            cache.isRejected(key: effectiveKey, suffix: suffix)
                || (key != nil && cache.isRejected(key: key!, suffix: suffix))
        }
        let llmCandidate = CommandCandidate(
            source: llmSource.name,
            authority: .generative,
            suggestion: sug,
            rawScore: ranker.score(suggestion: sug, source: llmSource.name)
        )
        // Keep non-LLM candidates, append incoming LLM candidate, and re-rank via CandidateRanker
        let existingNonLLM = currentCandidates.filter { $0.source != llmSource.name }
        let allCandidates = existingNonLLM + [llmCandidate]
        let rankedList = CandidateRanker.rank(candidates: allCandidates, isRejected: isRejected)
        setRankedCandidates(rankedList, generation: generation)

        if let k = key, !sug.text.isEmpty { cache.store(suffix: sug.text, for: k) }
        if key == nil, !sug.text.isEmpty { cache.store(suffix: sug.text, for: effectiveKey) }
    }
}
