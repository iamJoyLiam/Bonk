//  CandidateSource.swift
//  Bonk
//
//  Inline suggestion sources — one pipeline, many candidates.
//  LLM is just another CandidateSource, not a serial stage.
//

import Foundation

/// One candidate source in the Inline pipeline.
/// Sync sources return immediately (history, knownWords, cache); async sources may await (LLM).
protocol InlineCandidateSource: Sendable {
    /// Human-readable source name for logging/telemetry.
    var name: String { get }
    /// Return a Suggestion for the given snapshot+typed text, or nil if no candidate.
    /// `typed` is trimmed inputBuffer (already validated >=2 chars by pipeline).
    func suggestion(for snapshot: CommandContextSnapshot, typed: String) async -> Suggestion?
}

/// Convenience for sync sources.
protocol SyncInlineCandidateSource: InlineCandidateSource {
    func syncSuggestion(for snapshot: CommandContextSnapshot, typed: String) -> Suggestion?
}

extension SyncInlineCandidateSource {
    func suggestion(for snapshot: CommandContextSnapshot, typed: String) async -> Suggestion? {
        syncSuggestion(for: snapshot, typed: typed)
    }
}

// MARK: - Candidate ranking input

/// Collection of candidates from all sources before ranking.
struct InlineCandidateSet: Sendable {
    var candidates: [(source: String, suggestion: Suggestion)]

    var isEmpty: Bool { candidates.isEmpty }
    var best: Suggestion? { candidates.first?.suggestion }
}
