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
    private(set) var rankedCandidates: [InlineCandidate] = []
    private var currentCandidates: [CommandCandidate] = []
    private(set) var engagement: SuggestionEngagement = .passive

    /// Current selected index if engaged, or nil if passive.
    var selectedIndex: Int? {
        engagement.selectedIndex
    }

    /// Selected suggestion (ghost text) — computed from ranked + engagement.
    /// In passive mode, defaults to the top recommended candidate (ranked.first).
    /// In engaged mode, corresponds to the explicitly selected candidate.
    var suggestion: Suggestion? {
        guard !ranked.isEmpty else { return nil }
        switch engagement {
        case .passive:
            return ranked.first?.1
        case .engaged(let index):
            let safeIndex = max(0, min(index, ranked.count - 1))
            return ranked[safeIndex].1
        }
    }
    /// View callback for ghost updates — pipeline remains UI-agnostic, View subscribes.
    var onSuggestionChanged: ((Suggestion?) -> Void)?
    var onRequestingChanged: ((Bool) -> Void)?
    /// Candidate list changed: (count, engagement). Count <= 1 hides the popup.
    var onCandidatesChanged: ((Int, SuggestionEngagement) -> Void)?

    private let logger = Logger(subsystem: "com.bonk", category: "InlinePipeline")
    private let generationController = GenerationController()
    private let cache: InlineSuggestionCache
    private let ranker = InlineRanker()
    private let providerStore: AIProviderStore
    private let candidatePool: CandidatePool
    private let reranker: AIReranker

    private let knownWordsSource = KnownWordsCandidateSource()
    private let historySource = HistoryCandidateSource()
    private let vocabularySource = CommandVocabularySource()
    private let llmSource: LLMCandidateSource

    /// Cap for the candidate popup — best-ranked entries survive.
    private static let maxCandidates = 5

    private var currentKey: String?
    private var currentEffectiveKey: String?
    private var lastKeystrokeTime: Date?
    private var presentationTask: Task<Void, Never>?

    init(
        providerStore: AIProviderStore = .shared,
        cache: InlineSuggestionCache = InlineSuggestionCache(),
        candidatePool: CandidatePool = CandidatePool(),
        reranker: AIReranker = .shared
    ) {
        self.providerStore = providerStore
        self.cache = cache
        self.candidatePool = candidatePool
        self.reranker = reranker
        self.llmSource = LLMCandidateSource(providerStore: providerStore, cache: cache)
    }

    func attachModelContext(_ ctx: SwiftData.ModelContext) {
        cache.attachModelContext(ctx)
    }

    // MARK: - Public

    func request(snapshot: CommandContextSnapshot) {
        let now = Date()
        let interval = lastKeystrokeTime.map { now.timeIntervalSince($0) } ?? 1.0
        let isTypingFast = interval < 0.16
        lastKeystrokeTime = now
        let trimmedLeading = String(snapshot.inputBuffer.drop(while: { $0.isWhitespace || $0.isNewline }))
        let typed = trimmedLeading.trimmingCharacters(in: .newlines)
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            cancel()
            return
        }
        let gen = generationController.bumpGeneration()
        // Tier 1: deterministic local candidates (knownWords/cache/history) —
        // instant, no debounce. Warp-style: local ghost appears immediately.
        performLocal(snapshot: snapshot, typed: typed, generation: gen, isTypingFast: isTypingFast)

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
        presentationTask?.cancel()
        presentationTask = nil
        currentCandidates = []
        ranked = []
        rankedCandidates = []
        engagement = .passive
        onSuggestionChanged?(nil)
        onCandidatesChanged?(0, .passive)
        currentKey = nil
        currentEffectiveKey = nil
        isRequesting = false
        onRequestingChanged?(false)
    }

    /// Move the candidate selection (↑/↓ in the popup).
    /// Passive + ↓ advances to candidate 1 (or 0 if single candidate); Passive + ↑ engages at last candidate.
    /// Engaged + ↑/↓ changes index with boundary clamping.
    func moveSelection(_ delta: Int) {
        guard !ranked.isEmpty else { return }
        switch engagement {
        case .passive:
            let target = delta > 0 ? (ranked.count > 1 ? 1 : 0) : max(0, ranked.count - 1)
            engagement = .engaged(index: target)
        case .engaged(let current):
            let target = max(0, min(ranked.count - 1, current + delta))
            engagement = .engaged(index: target)
        }
        onSuggestionChanged?(suggestion)
        onCandidatesChanged?(ranked.count, engagement)
    }

    /// Directly select a candidate by index.
    func selectIndex(_ index: Int) {
        guard !ranked.isEmpty else { return }
        let target = max(0, min(ranked.count - 1, index))
        engagement = .engaged(index: target)
        onSuggestionChanged?(suggestion)
        onCandidatesChanged?(ranked.count, engagement)
    }

    /// Reset engagement back to passive (called on typing or backspace).
    func resetEngagement() {
        if engagement != .passive {
            engagement = .passive
            onSuggestionChanged?(suggestion)
            onCandidatesChanged?(ranked.count, .passive)
        }
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

    private func performLocal(snapshot: CommandContextSnapshot, typed: String, generation: UInt64, isTypingFast: Bool) {
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

        // P1 Candidate Pool: CLI Spec + History + Vocabulary + KnownWords + Cache, hard-filtered & local-ranked
        let candidates = candidatePool.buildCandidates(
            typed: typed,
            snapshot: snapshot,
            cache: cache,
            cacheKey: key,
            isRejected: isRejected
        )

        setRankedCandidates(candidates, typed: typed, generation: generation, isTypingFast: isTypingFast)

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
        guard !currentCandidates.isEmpty else { return }

        let provider = providerStore.activeProvider
        guard let p = provider, (!p.type.needsAPIKey || !p.apiKey.isEmpty) else { return }

        // P1 Optional AI Reranking: LLM ONLY reranks candidates in Candidate Pool; never invents commands.
        isRequesting = true
        onRequestingChanged?(true)
        defer {
            if generationController.isCurrent(generation) {
                isRequesting = false
                onRequestingChanged?(false)
            }
        }

        let reranked = await reranker.rerank(
            candidates: currentCandidates,
            typed: typed,
            snapshot: snapshot,
            provider: p,
            apiKey: p.apiKey
        )

        guard generationController.isCurrent(generation) else { return }
        setRankedCandidates(reranked, typed: typed, generation: generation, isTypingFast: false)
    }

    /// Replace the pipeline candidate list using ranked CommandCandidates and presentation policy.
    private func setRankedCandidates(_ list: [CommandCandidate], typed: String, generation: UInt64, isTypingFast: Bool = false) {
        guard generationController.isCurrent(generation) else { return }
        applyPresentation(list: list, typed: typed, isTypingFast: isTypingFast, generation: generation)
    }

    private func applyPresentation(
        list: [CommandCandidate],
        typed: String,
        isTypingFast: Bool,
        generation: UInt64
    ) {
        guard generationController.isCurrent(generation) else { return }
        currentCandidates = list
        let action = InlinePresentationPolicy.evaluate(
            ranked: list,
            inputBuffer: typed,
            isTypingFast: isTypingFast
        )
        switch action {
        case .show(let sug, let showPopup):
            ranked = Array(list.map { ($0.source, $0.suggestion) }.prefix(Self.maxCandidates))
            rankedCandidates = Array(list.prefix(Self.maxCandidates))
            engagement = .passive
            onSuggestionChanged?(sug)
            onCandidatesChanged?(showPopup ? ranked.count : 0, .passive)
        case .hide:
            ranked = []
            rankedCandidates = []
            engagement = .passive
            onSuggestionChanged?(nil)
            onCandidatesChanged?(0, .passive)
        case .delay(let ms):
            presentationTask?.cancel()
            presentationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                guard let self, self.generationController.isCurrent(generation), !Task.isCancelled else { return }
                self.applyPresentation(list: list, typed: typed, isTypingFast: false, generation: generation)
            }
        }
    }

    /// LLM stream commit — routes through CandidateRanker without force-promoting above deterministic candidates.
    private func commitLLM(_ sug: Suggestion, typed: String, key: String?, generation: UInt64, effectiveKey: String) {
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
        setRankedCandidates(rankedList, typed: typed, generation: generation)

        if let k = key, !sug.text.isEmpty { cache.store(suffix: sug.text, for: k) }
        if key == nil, !sug.text.isEmpty { cache.store(suffix: sug.text, for: effectiveKey) }
    }
}
