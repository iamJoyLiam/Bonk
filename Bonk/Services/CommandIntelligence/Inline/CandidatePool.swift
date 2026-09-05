//
//  CandidatePool.swift
//  Bonk
//
//  P1 Candidate Pool & Hard Filter.
//  Aggregates candidates from CLI Spec, History, Runtime Context, and Vocabulary,
//  then applies strict hard filtering before ranking.
//

import Foundation

/// Pipeline stage that generates and hard-filters the candidate pool.
final class CandidatePool: @unchecked Sendable {
    private let cliRegistry: CLISpecRegistry
    private let historySource: HistoryCandidateSource
    private let vocabularySource: CommandVocabularySource
    private let knownWordsSource: KnownWordsCandidateSource
    private let ranker: InlineRanker

    // P0.4: Incremental candidate cache
    private var lastQuery: (typed: String, hostKey: String, candidates: [CommandCandidate])?

    init(
        cliRegistry: CLISpecRegistry = .shared,
        historySource: HistoryCandidateSource = HistoryCandidateSource(),
        vocabularySource: CommandVocabularySource = CommandVocabularySource(),
        knownWordsSource: KnownWordsCandidateSource = KnownWordsCandidateSource(),
        ranker: InlineRanker = InlineRanker()
    ) {
        self.cliRegistry = cliRegistry
        self.historySource = historySource
        self.vocabularySource = vocabularySource
        self.knownWordsSource = knownWordsSource
        self.ranker = ranker
    }

    /// Build and hard-filter the candidate pool for a typed buffer and context snapshot.
    @MainActor
    func buildCandidates(
        typed: String,
        snapshot: CommandContextSnapshot,
        cache: InlineSuggestionCache?,
        cacheKey: String?,
        isRejected: (String) -> Bool
    ) -> [CommandCandidate] {
        let trimmedTyped = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTyped.isEmpty else {
            lastQuery = nil
            return []
        }

        let hostKey = snapshot.hostKey ?? ""

        // P0.4: Exact query cache hit
        if let last = lastQuery, last.typed == typed, last.hostKey == hostKey {
            return last.candidates.filter { !isRejected($0.suggestion.text) }
        }

        // P0.4: Incremental filtering if typed extends lastQuery prefix
        if let last = lastQuery, last.hostKey == hostKey, typed.hasPrefix(last.typed), !last.candidates.isEmpty {
            let incremental = last.candidates.compactMap { cand -> CommandCandidate? in
                guard let full = cand.suggestion.fullText else { return nil }
                guard full.lowercased().hasPrefix(trimmedTyped.lowercased()) && full.count > typed.count else { return nil }
                let suffix = String(full.dropFirst(typed.count))
                guard !suffix.isEmpty, !isRejected(suffix) else { return nil }
                let display = SuggestionFormatter.displaySuffix(suffix, typed: typed)
                let newSug = Suggestion(text: suffix, displayText: display, fullText: full)
                return CommandCandidate(
                    source: cand.source,
                    authority: cand.authority,
                    suggestion: newSug,
                    rawScore: cand.rawScore,
                    isExactPrefixMatch: true
                )
            }
            if !incremental.isEmpty {
                let ranked = CandidateRanker.rank(candidates: incremental, isRejected: isRejected)
                lastQuery = (typed, hostKey, ranked)
                return ranked
            }
        }

        var pool: [CommandCandidate] = []

        // 1. CLI Spec (Hard Gate for commands like docker, git, kubectl, etc.)
        let cliCandidates = cliRegistry.candidates(for: typed)
        pool.append(contentsOf: cliCandidates)

        // 2. History Candidates (only when typed >= 2 characters to avoid aggressive ghosting on 1st char)
        if trimmedTyped.count >= 2 {
            if let histSug = historySource.syncSuggestion(for: snapshot, typed: typed) {
                let full = histSug.withFullCommand(typed: typed)
                let score = ranker.score(suggestion: full, source: historySource.name)
                pool.append(CommandCandidate(
                    source: historySource.name,
                    authority: .deterministic,
                    suggestion: full,
                    rawScore: score + 5.0, // Habit bonus for user's own past commands
                    isExactPrefixMatch: true
                ))
            }

            // Also check snapshot.recentCommands for prefix matches (with normalized whitespace)
            let normalizedTyped = typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for cmd in snapshot.recentCommands.reversed() {
                let normalizedCmd = cmd.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if (normalizedCmd.hasPrefix(typed) && normalizedCmd.count > typed.count) ||
                   (normalizedCmd.hasPrefix(normalizedTyped) && normalizedCmd.count > normalizedTyped.count) {
                    let prefixLen = normalizedCmd.hasPrefix(typed) ? typed.count : normalizedTyped.count
                    let suffix = String(normalizedCmd.dropFirst(prefixLen))
                    guard !suffix.isEmpty else { continue }
                    let display = SuggestionFormatter.displaySuffix(suffix, typed: typed)
                    let sug = Suggestion(text: suffix, displayText: display, fullText: normalizedCmd)
                    let score = ranker.score(suggestion: sug, source: "history")
                    pool.append(CommandCandidate(
                        source: "history",
                        authority: .deterministic,
                        suggestion: sug,
                        rawScore: score,
                        isExactPrefixMatch: true
                    ))
                }
            }
        }

        let tokens = typed.split(whereSeparator: \.isWhitespace)
        let rootCommand = tokens.first.map(String.init)?.lowercased() ?? ""
        let isKnownCLI = cliRegistry.spec(for: rootCommand) != nil

        // 3. Command Index (Root commands e.g. dock -> docker, df, du, etc.)
        if !isKnownCLI && !typed.contains(" ") {
            let indexMatches = CompositeCommandIndex.shared.matches(prefix: typed, limit: 5)
            if !indexMatches.isEmpty {
                pool.append(contentsOf: indexMatches)
            } else if trimmedTyped.count >= 2, let vocabSug = vocabularySource.syncSuggestion(for: snapshot, typed: typed) {
                let full = vocabSug.withFullCommand(typed: typed)
                let score = ranker.score(suggestion: full, source: vocabularySource.name)
                pool.append(CommandCandidate(
                    source: vocabularySource.name,
                    authority: .deterministic,
                    suggestion: full,
                    rawScore: score,
                    isExactPrefixMatch: true
                ))
            }
        }

        // 4. Runtime Context / Known Words (Screen output tokens)
        // For known CLI tools, only query known words for parameters/arguments, never to mangle subcommands.
        // Never query known words when user is on whitespace or for single character.
        let shouldQueryKnownWords: Bool = {
            guard trimmedTyped.count >= 2 else { return false }
            guard !typed.hasSuffix(" ") else { return false }
            guard !isKnownCLI else {
                return tokens.count >= 3
            }
            return true
        }()

        if shouldQueryKnownWords, let kwSug = knownWordsSource.syncSuggestion(for: snapshot, typed: typed) {
            let full = kwSug.withFullCommand(typed: typed)
            let score = ranker.score(suggestion: full, source: knownWordsSource.name)
            pool.append(CommandCandidate(
                source: knownWordsSource.name,
                authority: .contextual,
                suggestion: full,
                rawScore: score
            ))
        }

        // 5. Cached Suggestions
        if let k = cacheKey, let cached = cache?.cachedSuffix(for: k) {
            let display = SuggestionFormatter.displaySuffix(cached, typed: typed)
            let sug = Suggestion(text: cached, displayText: display).withFullCommand(typed: typed)
            pool.append(CommandCandidate(
                source: "cache",
                authority: .deterministic,
                suggestion: sug,
                rawScore: 90.0
            ))
        }

        // 6. Hard Filter:
        // - Reject suggestions where full command does not align with typed buffer
        // - Reject suggestions in rejection cache
        // - Deduplicate identical fullText or text
        let filtered = pool.filter { candidate in
            let text = candidate.suggestion.text
            guard !text.isEmpty, !isRejected(text) else { return false }

            // Hard filter alignment:
            if let full = candidate.suggestion.fullText {
                guard full.lowercased().hasPrefix(trimmedTyped.lowercased()) || full.contains(trimmedTyped) else {
                    return false
                }
            }
            return true
        }

        // 7. Local Ranking:
        let ranked = CandidateRanker.rank(candidates: filtered, isRejected: isRejected)
        lastQuery = (typed, hostKey, ranked)
        return ranked
    }
}
