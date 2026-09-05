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

/// Origin source of an inline command candidate.
enum CandidateSource: String, Sendable, Codable, Equatable, CaseIterable {
    case vocabulary = "vocabulary"
    case pathExecutable = "path"
    case history = "history"
    case cliSpec = "cliSpec"
    case ai = "llm"
    case cache = "cache"
    case contextual = "knownWords"
    case other = "other"

    init(string: String) {
        switch string.lowercased() {
        case "vocabulary": self = .vocabulary
        case "path": self = .pathExecutable
        case "history": self = .history
        case "clispec": self = .cliSpec
        case "llm", "ai", "generative": self = .ai
        case "cache": self = .cache
        case "knownwords", "knownwordssorted", "contextual": self = .contextual
        default: self = .other
        }
    }

    var isAI: Bool { self == .ai }
}

/// Additional structural metadata associated with a candidate.
struct CandidateMetadata: Sendable, Equatable {
    var fullCommand: String?
    var isExactPrefixMatch: Bool = false
    var tags: [String] = []

    init(fullCommand: String? = nil, isExactPrefixMatch: Bool = false, tags: [String] = []) {
        self.fullCommand = fullCommand
        self.isExactPrefixMatch = isExactPrefixMatch
        self.tags = tags
    }
}

/// Unified candidate domain model for inline command suggestions.
struct CommandCandidate: Sendable, Identifiable, Equatable {
    let source: String
    let typedSource: CandidateSource
    let authority: CandidateAuthority
    let text: String
    let displayText: String
    let fullText: String?
    let summary: String?
    let score: Double
    let isExactPrefixMatch: Bool
    let metadata: CandidateMetadata?

    /// Compatibility with CommandCandidate
    var rawScore: Double { score }
    var suggestion: Suggestion {
        Suggestion(text: text, displayText: displayText, fullText: fullText)
    }

    /// Stable deterministic identity across evaluations and pipeline runs.
    var id: String {
        "\(authority)|\(source)|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    init(
        source: String,
        authority: CandidateAuthority,
        text: String,
        displayText: String? = nil,
        fullText: String? = nil,
        summary: String? = nil,
        score: Double,
        isExactPrefixMatch: Bool = false,
        metadata: CandidateMetadata? = nil
    ) {
        self.source = source
        self.typedSource = CandidateSource(string: source)
        self.authority = authority
        self.text = text
        self.displayText = displayText ?? text
        self.fullText = fullText
        self.summary = summary
        self.score = score
        self.isExactPrefixMatch = isExactPrefixMatch
        self.metadata = metadata
    }

    /// Exact original signature for binary compatibility
    init(
        source: String,
        authority: CandidateAuthority,
        suggestion: Suggestion,
        rawScore: Double,
        isExactPrefixMatch: Bool = false
    ) {
        self.init(
            source: source,
            authority: authority,
            text: suggestion.text,
            displayText: suggestion.displayText,
            fullText: suggestion.fullText,
            summary: nil,
            score: rawScore,
            isExactPrefixMatch: isExactPrefixMatch,
            metadata: nil
        )
    }

    /// Convenience initializer bridging from Suggestion with summary
    init(
        source: String,
        authority: CandidateAuthority,
        suggestion: Suggestion,
        rawScore: Double,
        isExactPrefixMatch: Bool = false,
        summary: String? = nil,
        metadata: CandidateMetadata? = nil
    ) {
        self.init(
            source: source,
            authority: authority,
            text: suggestion.text,
            displayText: suggestion.displayText,
            fullText: suggestion.fullText,
            summary: summary,
            score: rawScore,
            isExactPrefixMatch: isExactPrefixMatch,
            metadata: metadata
        )
    }

    /// Convenience initializer bridging from Suggestion with typed CandidateSource
    init(
        source: CandidateSource,
        authority: CandidateAuthority,
        suggestion: Suggestion,
        rawScore: Double,
        isExactPrefixMatch: Bool = false,
        summary: String? = nil,
        metadata: CandidateMetadata? = nil
    ) {
        self.init(
            source: source.rawValue,
            authority: authority,
            text: suggestion.text,
            displayText: suggestion.displayText,
            fullText: suggestion.fullText,
            summary: summary,
            score: rawScore,
            isExactPrefixMatch: isExactPrefixMatch,
            metadata: metadata
        )
    }

    /// Convenience initializer using typed CandidateSource
    init(
        source: CandidateSource,
        authority: CandidateAuthority,
        text: String,
        displayText: String? = nil,
        fullText: String? = nil,
        summary: String? = nil,
        score: Double,
        isExactPrefixMatch: Bool = false,
        metadata: CandidateMetadata? = nil
    ) {
        self.init(
            source: source.rawValue,
            authority: authority,
            text: text,
            displayText: displayText,
            fullText: fullText,
            summary: summary,
            score: score,
            isExactPrefixMatch: isExactPrefixMatch,
            metadata: metadata
        )
    }
}

/// Unified domain model alias
typealias InlineCandidate = CommandCandidate
