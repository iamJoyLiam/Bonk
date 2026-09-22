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
    private let reranker: CommandDecisionEngine

    private let knownWordsSource = KnownWordsCandidateSource()
    private let historySource = HistoryCandidateSource()
    private let vocabularySource = CommandVocabularySource()
    private let llmSource: LLMCandidateSource
    /// Engine identity source (injectable for tests). Defaults to the
    /// in-memory settings snapshot — never UserDefaults I/O on the key path.
    /// Switching engines invalidates the shown ghost — a stale suggestion
    /// from the previous engine must never survive the switch.
    private let engineIDProvider: @Sendable () -> String
    private var lastEngineID: String?

    /// Cap for the candidate popup — best-ranked entries survive.
    private static let maxCandidates = 5

    private var currentKey: String?
    private var currentEffectiveKey: String?
    private var lastKeystrokeTime: Date?
    private var presentationTask: Task<Void, Never>?
    /// Anchor of the currently shown suggestion: the typed buffer (and known
    /// cursor offset) the suggestion was computed for. Accept verifies the
    /// live editor state against it before inserting.
    private(set) var suggestionAnchor: (typed: String, offset: Int?)?

    init(
        providerStore: AIProviderStore = .shared,
        cache: InlineSuggestionCache = InlineSuggestionCache(),
        candidatePool: CandidatePool = CandidatePool(),
        reranker: CommandDecisionEngine = .shared,
        engineIDProvider: @Sendable @escaping () -> String = { AIInlineSettings.current.decisionEngineID }
    ) {
        self.providerStore = providerStore
        self.cache = cache
        self.candidatePool = candidatePool
        self.reranker = reranker
        self.engineIDProvider = engineIDProvider
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
        // Engine switch invalidates everything shown: cancel first so the
        // previous engine's ghost/popup never survives the switch.
        // Reads the in-memory settings snapshot — no UserDefaults I/O here.
        let engineID = AIInlineSettings.current.decisionEngineID
        if lastEngineID != engineID {
            cancel()
            lastEngineID = engineID
        }
        let trimmedLeading = String(snapshot.inputBuffer.drop(while: { $0.isWhitespace || $0.isNewline }))
        let typed = trimmedLeading.trimmingCharacters(in: .newlines)
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancel()
            return
        }
        // A-switches: skip all candidate work when neither surface is on.
        let switches = AIInlineSettings.current
        guard switches.ghostSuggestionsEnabled || switches.candidatePopupEnabled else {
            cancel()
            return
        }
        let gen = generationController.bumpGeneration()
        logger.debug("B-request: typed=\(typed) offset=\(snapshot.cursorOffset.map(String.init) ?? "nil")")
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
            if typed.hasSuffix(" ") {
                return .medium(candidates: candidates.map(\.suggestion))
            }
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
        suggestionAnchor = nil
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

    func accept(currentTyped: String? = nil, currentAtLineEnd: Bool = true) -> String {
        guard let s = suggestion else { return "" }
        // B-defense (passive ghost only): verify the live editor still holds
        // the anchor — cursor moved or mid-line edits reject the stale ghost.
        // Engaged popup selection is an explicit user choice and bypasses it.
        if case .passive = engagement {
            let typedNow = currentTyped ?? suggestionAnchor?.typed
            let anchorDesc = suggestionAnchor?.typed ?? "nil"
            guard let anchor = suggestionAnchor, let typedNow,
                  CursorContext.anchorAllowsInsert(anchorBuffer: anchor.typed, currentBuffer: typedNow),
                  currentAtLineEnd
            else {
                logger.debug("B-reject: anchor=\(anchorDesc) current=\(typedNow ?? "nil") eol=\(currentAtLineEnd)")
                cancel()
                return ""
            }
            logger.debug("B-accept: anchor=\(anchor.typed) current=\(typedNow) ghostLen=\(s.text.count)")
        }
        if let key = currentKey { cache.markAccepted(for: key) }
        UserProfile.shared.recordAccept(suffix: s.text)
        let text = s.text
        // Accept attribution for engine effectiveness stats (fire-and-forget).
        // Links the outcome to the winning trace for calibration buckets.
        let acceptedEngine = engineIDProvider()
        let acceptedID: String? = {
            if case let .engaged(index) = engagement,
               rankedCandidates.indices.contains(index) {
                return rankedCandidates[index].id
            }
            return rankedCandidates.first?.id
        }()
        Task { await DecisionTraceRecorder.shared.recordAccept(engine: acceptedEngine, selectedID: acceptedID) }
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

        setRankedCandidates(
            candidates, typed: typed, cursor: snapshot.cursorContext,
            generation: generation, isTypingFast: isTypingFast
        )

        // Cache the top local candidate for parity with previous commit behavior.
        if let k = key, let first = ranked.first, !first.1.text.isEmpty {
            cache.store(suffix: first.1.text, for: k)
        }
        if key == nil, let first = ranked.first, !first.1.text.isEmpty {
            cache.store(suffix: first.1.text, for: effectiveKey)
        }
    }

    @MainActor private func resolveProvider(snapshot: CommandContextSnapshot) -> (AIProviderConfig, String)? {
        let defaults = UserDefaults.standard
        let overrideID = defaults.string(forKey: "ai_inline_provider_id") ?? ""
        let provider: AIProviderConfig?
        if !overrideID.isEmpty {
            provider = providerStore.providers.first { $0.id.uuidString == overrideID }
        } else {
            provider = ModelRouter.shared.provider(for: IntelligenceTask.inlineCompletion, snapshot: snapshot) ?? providerStore.activeProvider
        }
        guard var p = provider ?? providerStore.providers.first(where: { !$0.apiKey.isEmpty || !$0.type.needsAPIKey }) else { return nil }
        if let inlineModel = defaults.string(forKey: "ai_inline_model"),
           !inlineModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p.model = inlineModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = p.apiKey
        guard !p.type.needsAPIKey || !key.isEmpty else { return nil }
        return (p, key)
    }

    private func performLLM(snapshot: CommandContextSnapshot, typed: String, generation: UInt64) async {
        guard generationController.isCurrent(generation) else { return }

        let isNaturalLanguage = typed.hasPrefix("#") || InlineTriggerPolicy.isNaturalLanguageIntent(typed)
        let decisionConfig = DecisionEngineConfig.load()

        isRequesting = true
        onRequestingChanged?(true)
        defer {
            if generationController.isCurrent(generation) {
                isRequesting = false
                onRequestingChanged?(false)
            }
        }

        if isNaturalLanguage {
            guard let (p, apiKey) = resolveProvider(snapshot: snapshot) else {
                logger.debug("[InlinePipeline] natural-language channel skipped: no LLM provider resolved")
                return
            }
            // Mode B: Natural Language Intent Translation Channel
            let prompt = InlinePromptBuilder.buildNaturalLanguagePrompt(snapshot: snapshot, query: typed)
            let llm = LLMProviderFactory.provider(for: p, apiKey: apiKey, workload: .inlineCompletion)
            do {
                let response = try await llm.chat(
                    messages: [
                        .system(prompt),
                        .user(typed)
                    ],
                    maxTokens: 64,
                    disableReasoning: true
                )
                guard generationController.isCurrent(generation) else { return }
                guard let sug = LLMCompletionAdapter.adaptNaturalLanguage(rawOutput: response.text, typed: typed) else {
                    return
                }

                let aiCandidate = CommandCandidate(
                    source: CandidateSource.ai.rawValue,
                    authority: .generative,
                    suggestion: sug,
                    rawScore: 99.0,
                    summary: String(format: L.t(.inlineSummaryTranslated), sug.fullText ?? sug.displayText)
                )

                let combined = CandidateRanker.balanceChannels(
                    ranked: [aiCandidate] + currentCandidates,
                    totalLimit: Self.maxCandidates,
                    maxAICandidates: 1
                )
                setRankedCandidates(
                    combined, typed: typed, cursor: snapshot.cursorContext,
                    generation: generation, isTypingFast: false
                )
            } catch {
                logger.debug("[InlinePipeline] Natural language translation skipped or failed: \(error.localizedDescription)")
            }
        } else {
            // Mode A: the configured engine orders the pool (no LLM provider
            // needed; the deterministic fallback keeps local order when the
            // engine is unconfigured). Generative AI completion still appends
            // when an LLM provider exists.
            let engine = DecisionEngineFactory.makeEffective(config: decisionConfig)
            let recentOutput = snapshot.recentOutput.suffix(300).trimmingCharacters(in: .whitespacesAndNewlines)
            let state = "Recent output: \(recentOutput)"
            let providerPair = resolveProvider(snapshot: snapshot)
            // Prompt building is MainActor-isolated; hoist it out of the
            // nonisolated async-let below.
            let generativeInputs: (AIProviderConfig, String, String)? = providerPair.map { (p, key) in
                (p, key, InlinePromptBuilder.buildPrompt(snapshot: snapshot))
            }

            async let orderedTask = reranker.decideBest(
                candidates: currentCandidates,
                typed: typed,
                state: state,
                engine: engine,
                decisionThreshold: AIInlineSettings.current.decisionThreshold
            )

            async let generativeTask: CommandCandidate? = {
                guard let (p, apiKey, prompt) = generativeInputs else { return nil }
                let llm = LLMProviderFactory.provider(for: p, apiKey: apiKey, workload: .inlineCompletion)
                do {
                    let response = try await llm.chat(
                        messages: [
                            .system(prompt),
                            .user(typed)
                        ],
                        maxTokens: 32,
                        disableReasoning: true
                    )
                    guard let sug = LLMCompletionAdapter.adapt(rawOutput: response.text, typed: typed) else {
                        return nil
                    }
                    let full = sug.withFullCommand(typed: typed)
                    return CommandCandidate(
                        source: CandidateSource.ai.rawValue,
                        authority: .generative,
                        suggestion: full,
                        rawScore: 70.0,
                        summary: L.t(.inlineSummaryPredicted)
                    )
                } catch {
                    return nil
                }
            }()

            let ordered = await orderedTask ?? currentCandidates
            let aiCandidate = await generativeTask

            guard generationController.isCurrent(generation) else { return }
            var combined = ordered
            if let aiCandidate {
                let aiFull = (aiCandidate.suggestion.fullText ?? aiCandidate.suggestion.displayText).trimmingCharacters(in: .whitespaces)
                if !combined.contains(where: { ($0.suggestion.fullText ?? $0.suggestion.displayText).trimmingCharacters(in: .whitespaces) == aiFull }) {
                    combined.append(aiCandidate)
                }
            }
            let balanced = CandidateRanker.balanceChannels(
                ranked: combined,
                totalLimit: Self.maxCandidates,
                maxAICandidates: 1
            )
            setRankedCandidates(
                balanced, typed: typed, cursor: snapshot.cursorContext,
                generation: generation, isTypingFast: false
            )
        }
    }

    /// Replace the pipeline candidate list using ranked CommandCandidates and presentation policy.
    private func setRankedCandidates(
        _ list: [CommandCandidate], typed: String, cursor: CursorContext,
        generation: UInt64, isTypingFast: Bool = false
    ) {
        guard generationController.isCurrent(generation) else { return }
        applyPresentation(list: list, typed: typed, cursor: cursor, isTypingFast: isTypingFast, generation: generation)
    }

    private func applyPresentation(
        list: [CommandCandidate],
        typed: String,
        cursor: CursorContext,
        isTypingFast: Bool,
        generation: UInt64
    ) {
        guard generationController.isCurrent(generation) else { return }
        let balanced = CandidateRanker.balanceChannels(
            ranked: list,
            totalLimit: Self.maxCandidates,
            maxAICandidates: 1
        )
        currentCandidates = balanced
        let settings = AIInlineSettings.current
        let action = InlinePresentationPolicy.evaluate(
            ranked: balanced,
            inputBuffer: typed,
            isTypingFast: isTypingFast,
            cursor: cursor,
            ghostEnabled: settings.ghostSuggestionsEnabled,
            popupEnabled: settings.candidatePopupEnabled
        )
        switch action {
        case .show(let sug, let showPopup):
            ranked = Array(balanced.map { ($0.source, $0.suggestion) })
            rankedCandidates = balanced
            engagement = .passive
            suggestionAnchor = (typed: typed, offset: cursor.offset)
            let anchorOffset = cursor.offset.map(String.init) ?? "nil"
            logger.debug("B-show: anchor=\(typed) offset=\(anchorOffset) ghostLen=\(sug.text.count) popup=\(showPopup)")
            onSuggestionChanged?(sug)
            onCandidatesChanged?(showPopup ? ranked.count : 0, .passive)
        case .popupOnly:
            ranked = Array(balanced.map { ($0.source, $0.suggestion) })
            rankedCandidates = balanced
            engagement = .passive
            suggestionAnchor = (typed: typed, offset: cursor.offset)
            let popupCount = ranked.count
            let anchorOffset = cursor.offset.map(String.init) ?? "nil"
            logger.debug("B-popupOnly: anchor=\(typed) offset=\(anchorOffset) count=\(popupCount)")
            onSuggestionChanged?(nil)
            onCandidatesChanged?(ranked.count, .passive)
        case .hide:
            ranked = []
            rankedCandidates = []
            engagement = .passive
            suggestionAnchor = nil
            onSuggestionChanged?(nil)
            onCandidatesChanged?(0, .passive)
        case .delay(let ms):
            presentationTask?.cancel()
            presentationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                guard let self, self.generationController.isCurrent(generation), !Task.isCancelled else { return }
                self.applyPresentation(
                    list: list, typed: typed, cursor: cursor,
                    isTypingFast: false, generation: generation
                )
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
        let balanced = CandidateRanker.balanceChannels(
            ranked: rankedList,
            totalLimit: Self.maxCandidates,
            maxAICandidates: 1
        )
        let unknownCursor = CursorContext.resolve(buffer: typed, cursorOffset: nil)
        setRankedCandidates(
            balanced, typed: typed, cursor: unknownCursor, generation: generation
        )

        if let k = key, !sug.text.isEmpty { cache.store(suffix: sug.text, for: k) }
        if key == nil, !sug.text.isEmpty { cache.store(suffix: sug.text, for: effectiveKey) }
    }
}
