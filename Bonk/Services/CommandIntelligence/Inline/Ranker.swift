//  Ranker.swift
//  Bonk
//
//  Ranks candidates from multiple sources. P0: deterministic priority + rejected filtering.
//  Future: scored ranking with context/profile.
//

import Foundation

struct InlineRanker: Sendable {
    /// Scored ranking: KnownWords (exact prefix length) > History (recency+length) > Cache > LLM (length+confidence)
    /// P0.12: keep deterministic priority but add lightweight scoring for tie-break.
    func rank(candidates: InlineCandidateSet, rejected: (String, String) -> Bool, key: String) -> Suggestion? {
        var scored: [(Suggestion, Double)] = []
        for (source, sug) in candidates.candidates {
            if rejected(key, sug.text) { continue }
            let score = score(suggestion: sug, source: source)
            scored.append((sug, score))
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    func firstNonRejected(in candidates: [(String, Suggestion)], isRejected: (String) -> Bool) -> Suggestion? {
        var best: (Suggestion, Double)?
        for (source, s) in candidates where !isRejected(s.text) {
            let sc = score(suggestion: s, source: source)
            if best == nil || sc > best!.1 { best = (s, sc) }
        }
        return best?.0
    }

    private func score(suggestion: Suggestion, source: String) -> Double {
        // Base priority by source
        let base: Double
        switch source {
        case "knownWords", "knownWordsSorted": base = 100
        case "cache": base = 90
        case "history": base = 80
        case "llm": base = 70
        default: base = 50
        }
        // Length heuristic: shorter, more precise suffix scores higher for local; longer for LLM may be richer
        let lenPenalty = Double(suggestion.text.count) * 0.05
        // Token boundary bonus: if display starts with space (new token), slightly higher
        let tokenBonus: Double = suggestion.displayText.hasPrefix(" ") ? 2 : 0
        return base - lenPenalty + tokenBonus
    }
}
