//  Candidate.swift
//  Bonk
//
//  Unified CommandCandidate model with authority tiers and stable deterministic identity.
//

import Foundation

/// Authority tier: deterministic sources have an absolute boundary over generative sources in ranking.
/// Kept as an un-comparable semantic enum so authority is exclusively interpreted by CandidateRanker.
enum CandidateAuthority: Sendable, Equatable, Hashable {
    case deterministic
    case contextual
    case generative
}

/// Unified candidate produced by any candidate source.
struct CommandCandidate: Sendable, Identifiable, Equatable {
    let source: String
    let authority: CandidateAuthority
    let suggestion: Suggestion
    let rawScore: Double
    let isExactPrefixMatch: Bool

    /// Stable deterministic identity across evaluations and pipeline runs.
    /// Does not rely on random UUID, ensuring robust caching, diffing, and telemetry.
    var id: String {
        "\(authority)|\(source)|\(suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    init(
        source: String,
        authority: CandidateAuthority,
        suggestion: Suggestion,
        rawScore: Double,
        isExactPrefixMatch: Bool = false
    ) {
        self.source = source
        self.authority = authority
        self.suggestion = suggestion
        self.rawScore = rawScore
        self.isExactPrefixMatch = isExactPrefixMatch
    }
}
