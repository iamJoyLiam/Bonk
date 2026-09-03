//  Ranker.swift
//  Bonk
//
//  Ranks candidates from multiple sources. P0: deterministic priority + rejected filtering.
//  Future: scored ranking with context/profile.
//

import Foundation

struct InlineRanker: Sendable {
    /// Priority: KnownWords > Cache > History > LLM (progressive replace semantics preserved for P0)
    func rank(candidates: InlineCandidateSet, rejected: (String, String) -> Bool, key: String) -> Suggestion? {
        for (_, sug) in candidates.candidates {
            if rejected(key, sug.text) { continue }
            return sug
        }
        return nil
    }

    /// Simple priority: first non-rejected wins (caller orders sources by priority)
    func firstNonRejected(in candidates: [(String, Suggestion)], isRejected: (String) -> Bool) -> Suggestion? {
        for (_, s) in candidates where !isRejected(s.text) { return s }
        return nil
    }
}
