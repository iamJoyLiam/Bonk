//  DeterministicDecisionEngine.swift
//  Bonk
//
//  Phase-1 DecisionEngine: pure local rules, no network, no model.
//  Exact match short-circuits; otherwise the highest local score wins;
//  gates compare caller-local confidence against the threshold.
//  Any model engine (Jev/Laya) must be swappable with this implementation
//  without changing callers.

import Foundation

/// Deterministic DecisionEngine. Total order, fully testable, zero I/O.
struct DeterministicDecisionEngine: DecisionEngine, Sendable {
    let engineName = "deterministic"
    let choiceConfidenceSource = "deterministic_rule"
    func choose(options: [DecisionOption], context _: DecisionContext) async throws -> ChoiceDecision {
        guard !options.isEmpty else {
            return ChoiceDecision(selectedID: nil, confidence: 1.0, rationale: .noCandidate)
        }
        if options.count == 1 {
            let only = options[0]
            return ChoiceDecision(selectedID: only.id, confidence: 1.0, rationale: .singleCandidate)
        }
        if let exact = options.first(where: \.isExactMatch) {
            return ChoiceDecision(selectedID: exact.id, confidence: 1.0, rationale: .exactMatch)
        }
        let best = options.max(by: { $0.localScore < $1.localScore })!
        // Confidence reflects rank separation, capped — deterministic engines
        // report certainty about the rule applied, not about the world.
        return ChoiceDecision(selectedID: best.id, confidence: 1.0, rationale: .highestLocalScore)
    }

    func gate(question _: String, context: DecisionContext) async throws -> GateDecision {
        let proceed = context.localConfidence >= context.decisionThreshold
        return GateDecision(
            shouldProceed: proceed,
            confidence: 1.0
        )
    }

    func score(option: DecisionOption, context _: DecisionContext) async throws -> ScoreDecision {
        ScoreDecision(score: option.localScore, confidence: 1.0)
    }
}
