//  DecisionEngine.swift
//  Bonk
//
//  Decision Intelligence layer (phase 1): typed decision contracts shared by
//  CommandIntelligence, ModelRouter, and AgentRuntime.
//
//  Invariant: deterministic policy sets the boundary; a probabilistic model
//  only decides inside the boundary. A model may raise protection, never
//  lower a code-defined security level.

import Foundation

// MARK: - Decision Inputs

/// One candidate produced by code (never by a model). The engine selects
/// among these; it must not invent new ones.
struct DecisionOption: Sendable, Hashable {
    /// Stable identifier agreed with the caller (candidate id, provider id…).
    let id: String
    /// Human-readable meaning of this option. Model engines match on meaning,
    /// so opaque ids (UUIDs) MUST carry a label; deterministic engines ignore it.
    let label: String
    /// Local deterministic score. Higher is better. Meaning is caller-defined.
    let localScore: Double
    /// Exact-match short-circuit signal (e.g. exact prefix typed by the user).
    let isExactMatch: Bool

    init(id: String, label: String = "", localScore: Double, isExactMatch: Bool = false) {
        self.id = id
        self.label = label
        self.localScore = localScore
        self.isExactMatch = isExactMatch
    }
}

/// Context for one decision. Carries facts, not interpretations.
struct DecisionContext: Sendable {
    /// Caller-local confidence in [0, 1] computed deterministically
    /// (e.g. from exact-match / local rank). Used by gates.
    let localConfidence: Double
    /// Gate threshold. A gate proceeds iff localConfidence >= threshold
    /// for the deterministic engine; model engines report their own
    /// confidence against the same threshold.
    let decisionThreshold: Double
    /// Free-form facts for model engines (never required by deterministic).
    let facts: [String: String]

    init(localConfidence: Double, decisionThreshold: Double = 0.75, facts: [String: String] = [:]) {
        self.localConfidence = localConfidence
        self.decisionThreshold = decisionThreshold
        self.facts = facts
    }
}

// MARK: - Typed Decisions (outputs — callers never interpret raw Double/Bool/String)

/// Why a decision came out the way it did. Deterministic reasons are
/// enumerable; model judgments carry their (optional) explanation.
enum DecisionRationale: Sendable, Equatable {
    case exactMatch
    case highestLocalScore
    case singleCandidate
    case noCandidate
    case decisionThresholdMet
    case decisionThresholdMissed
    case modelJudgment(String?)
}

/// Choice: select at most one option. nil selectedID means "none fits".
struct ChoiceDecision: Sendable, Equatable {
    let selectedID: String?
    let confidence: Double
    let rationale: DecisionRationale?
}

/// Gate: whether to proceed (show a suggestion, call a model, run a step…).
struct GateDecision: Sendable, Equatable {
    let shouldProceed: Bool
    let confidence: Double
}

/// Score: degree of one candidate against the caller's rubric.
struct ScoreDecision: Sendable, Equatable {
    let score: Double
    let confidence: Double
}

// MARK: - DecisionEngine Protocol

/// A decision engine answers typed questions over code-produced candidates.
/// Implementations: DeterministicDecisionEngine (phase 1), JevDecisionEngine
/// and LayaDecisionEngine (phase 2 adapters — same protocol, no caller change).
protocol DecisionEngine: Sendable {
    /// Stable engine label for traces and metrics ("deterministic", "jev", "laya").
    var engineName: String { get }
    /// What the Choice confidence number means ("jev_concentration" vs
    /// "laya_top_probability"). Raw values are never comparable across
    /// engines without this label.
    var choiceConfidenceSource: String { get }
    func choose(options: [DecisionOption], context: DecisionContext) async throws -> ChoiceDecision
    func gate(question: String, context: DecisionContext) async throws -> GateDecision
    func score(option: DecisionOption, context: DecisionContext) async throws -> ScoreDecision
}

// MARK: - Security: signal vs verdict are physically separated types

/// Advisory risk signal. A model may produce one; code produces one too.
/// A signal is NEVER an authorization result.
struct SecuritySignal: Sendable, Equatable {
    enum RiskLevel: String, Sendable {
        case low
        case elevated
        case high
    }

    let riskLevel: RiskLevel
    let confidence: Double
    let reason: String?

    static let benign = SecuritySignal(riskLevel: .low, confidence: 1.0, reason: nil)
}

/// Authorization verdict. Only Policy code (CommandSafety + PermissionPolicy)
/// constructs these, from deterministic rules combined with signals.
/// BLOCKED is terminal: no signal can downgrade it.
enum SecurityDecision: String, Sendable, Equatable {
    case allowed
    case confirmRequired
    case blocked
}
