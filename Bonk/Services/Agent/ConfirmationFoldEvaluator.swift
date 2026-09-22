//  ConfirmationFoldEvaluator.swift
//  Bonk
//
//  Phase 2 deterministic fold eligibility: decides whether an EXISTING
//  .confirmRequired verdict may be considered for confirmation folding.
//
//  Entry precondition (enforced by callers, re-checked here): only
//  .confirmRequired verdicts ever arrive. BLOCKED, readOnly violations,
//  and L3/L4 commands never reach the gate — the evaluator, not the
//  model, enforces this. Eligibility is a hard AND over level, effect,
//  and history. This evaluator never approves anything; it only answers
//  "is this confirmation allowed to meet the gate?".
//  Pure, synchronous, no I/O: fully unit-testable.

import Foundation

/// Why eligibility passed or failed. Short stable codes for trace/audit.
enum FoldEligibilityReason: String, Sendable {
    case eligible
    case unsupportedTool
    case levelTooHigh
    case unsafeEffect
    case noPriorApproval
    case priorDenial
}

struct FoldEligibility: Sendable, Equatable {
    let eligible: Bool
    let reason: FoldEligibilityReason
}

enum ConfirmationFoldEvaluator {
    /// Levels that may ever be folded. L3/L4 never reach the gate.
    /// (L0/L1 never arrive either — the policy auto-allows them — but
    /// the rule stays explicit so a future policy change cannot
    /// silently widen the fold surface.)
    private static let foldableLevels: Set<CommandSafetyLevel> = [
        .l0Explanation, .l1SafeInspection, .l2StateMutation,
    ]

    /// Checks fold eligibility. `facts` is the stored per-command history
    /// (nil = never seen). Only `run_command` carries levels and effects;
    /// every other tool is ineligible by construction.
    static func check(
        tool: String,
        level: CommandSafetyLevel?,
        effect: CommandEffectProfile,
        facts: CommandDecisionFacts?
    ) -> FoldEligibility {
        guard tool == "run_command", level != nil else {
            return FoldEligibility(eligible: false, reason: .unsupportedTool)
        }
        guard let level, foldableLevels.contains(level) else {
            return FoldEligibility(eligible: false, reason: .levelTooHigh)
        }
        guard effect.foldable else {
            return FoldEligibility(eligible: false, reason: .unsafeEffect)
        }
        switch facts?.previousDecision {
        case .approved:
            return FoldEligibility(eligible: true, reason: .eligible)
        case .denied:
            return FoldEligibility(eligible: false, reason: .priorDenial)
        case nil:
            return FoldEligibility(eligible: false, reason: .noPriorApproval)
        }
    }
}

// MARK: - Confirmation reason (UI fact line)

/// Localized one-line reason for a confirmation dialog, composed from
/// deterministic facts only (safety label + stored history word).
/// Displayed verbatim by the confirmation banner.
enum ConfirmationReason {
    static func describe(safetyLevel: String, history: CommandDecisionFacts?) -> String {
        let word: String
        switch history?.previousDecision {
        case .approved:
            word = L.t(.confirmHistApproved)
        case .denied:
            word = L.t(.confirmHistDenied)
        case nil:
            word = L.t(.confirmHistFirst)
        }
        return String(format: L.t(.confirmReason), safetyLevel, word)
    }
}
