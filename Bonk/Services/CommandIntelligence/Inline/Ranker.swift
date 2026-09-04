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

    /// Full ranked list, best first — feeds the Warp-style candidate popup.
    func sortedCandidates(
        in candidates: [(String, Suggestion)],
        isRejected: (String) -> Bool
    ) -> [(String, Suggestion)] {
        candidates
            .filter { !isRejected($0.1.text) }
            .map { entry -> ((String, Suggestion), Double) in (entry, score(suggestion: entry.1, source: entry.0)) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    func score(suggestion: Suggestion, source: String) -> Double {
        // Base priority by source
        let base: Double
        switch source {
        case "knownWords", "knownWordsSorted": base = 100
        case "cache": base = 90
        case "history": base = 80
        case "vocabulary": base = 75
        case "llm": base = 70
        default: base = 50
        }
        let lenPenalty = Double(suggestion.text.count) * 0.05
        let tokenBonus: Double = suggestion.displayText.hasPrefix(" ") ? 2 : 0
        let profileBoost = UserProfile.shared.boost(for: suggestion.text)
        let rejectedPenalty: Double = UserProfile.shared.isRejected(suffix: suggestion.text) ? -100 : 0
        return base - lenPenalty + tokenBonus + profileBoost + rejectedPenalty
    }
}

// MARK: - CandidateRanker (Authority-Enforced Ranking)

/// Ranks CommandCandidates by Authority Tier first, then by rawScore within the same tier.
struct CandidateRanker: Sendable {
    /// Authority priority: deterministic > contextual > generative.
    /// Encapsulated internally so outside code cannot treat authority as a raw numeric sort key.
    private static func tierPriority(_ authority: CandidateAuthority) -> Int {
        switch authority {
        case .deterministic: return 3
        case .contextual: return 2
        case .generative: return 1
        }
    }

    /// Ranks candidates: Authority tier determines boundary first; same tier sorts by rawScore.
    /// Excludes rejected suggestions, and deduplicates by suggestion text (keeping the higher-ranked entry).
    static func rank(
        candidates: [CommandCandidate],
        isRejected: (String) -> Bool = { _ in false }
    ) -> [CommandCandidate] {
        var seenTexts = Set<String>()
        return candidates
            .filter { candidate in
                !isRejected(candidate.suggestion.text)
            }
            .sorted { lhs, rhs in
                let lhsTier = tierPriority(lhs.authority)
                let rhsTier = tierPriority(rhs.authority)
                if lhsTier != rhsTier {
                    return lhsTier > rhsTier
                }
                return lhs.rawScore > rhs.rawScore
            }
            .filter { candidate in
                seenTexts.insert(candidate.suggestion.text).inserted
            }
    }
}

