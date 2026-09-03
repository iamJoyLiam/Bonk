//  LocalCandidateSource.swift
//  Bonk
//
//  Deterministic prefix completion from knownWords (recent terminal output).
//  Mirrors InlineCompletionService/SuggestionEngine knownWords logic verbatim for parity.
//

import Foundation

/// KnownWords candidate — completes last token from `snapshot.knownWords`.
final class KnownWordsCandidateSource: SyncInlineCandidateSource, @unchecked Sendable {
    let name = "knownWords"

    func syncSuggestion(for snapshot: CommandContextSnapshot, typed: String) -> Suggestion? {
        guard typed.count >= 2 else { return nil }
        guard let lastToken = typed.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let token = String(lastToken)
        guard let match = snapshot.knownWords.first(where: {
            $0.lowercased().hasPrefix(token.lowercased()) && $0.count > token.count
        }) else { return nil }
        let suffix = String(match.dropFirst(token.count))
        guard !suffix.isEmpty else { return nil }
        let display = SuggestionFormatter.displaySuffix(suffix, typed: typed)
        return Suggestion(text: suffix, displayText: display)
    }
}

/// Smaller wrapper that sorts by shortest match (as original Service did).
final class SortedKnownWordsCandidateSource: SyncInlineCandidateSource, @unchecked Sendable {
    let name = "knownWordsSorted"

    func syncSuggestion(for snapshot: CommandContextSnapshot, typed: String) -> Suggestion? {
        guard typed.count >= 2 else { return nil }
        guard let lastToken = typed.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let token = String(lastToken)
        guard let match = snapshot.knownWords
            .filter({ $0.lowercased().hasPrefix(token.lowercased()) && $0.count > token.count })
            .sorted(by: { $0.count < $1.count })
            .first else { return nil }
        let suffix = String(match.dropFirst(token.count))
        let display = SuggestionFormatter.displaySuffix(suffix, typed: typed)
        return Suggestion(text: suffix, displayText: display)
    }
}
