//  AgentBudgetController.swift
//  Bonk
//
//  Sole budget source for AgentRuntime. Value type owned by AgentRuntime;
//  mutate only from the driving task.
//
//  Phase 5 adds enforcement and token accounting. Token accounting uses
//  REPORTED usage only — nil usage never invents numbers. Token caps are
//  coarse guardrails pending per-model calibration.

import Foundation
import os

/// Budget warning. Advisory: observed via trace, never enforced.
enum BudgetWarning: Sendable, Equatable {
    case iterationsHigh(used: Int, max: Int)
    case wallClockHigh(elapsedMs: Double, maxMs: Double)
    case decisionCallsHigh(used: Int, max: Int)
    case inputTokensHigh(used: Int, max: Int)
    case outputTokensHigh(used: Int, max: Int)
}

/// Why a run was halted by budget enforcement.
enum BudgetExceededReason: String, Sendable {
    case iterations
    case wallClock
    case inputTokens
    case outputTokens
}

/// Sole budget keeper for one agent run.
struct AgentBudgetController: Sendable {
    var maxIterations: Int
    var maxWallClockMs: Double
    var maxDecisionCalls: Int
    /// Nil = unlimited. Only compared against reported usage.
    var maxInputTokens: Int?
    var maxOutputTokens: Int?

    private var iterationsUsed = 0
    private var toolCalls = 0
    private var decisionCalls = 0
    private var inputTokensUsed = 0
    private var outputTokensUsed = 0
    private var startDate = Date()
    private var warnedIterations = false
    private var warnedWallClock = false
    private var warnedDecisionCalls = false
    private var warnedInputTokens = false
    private var warnedOutputTokens = false

    private static let warnFraction = 0.8

    init(
        maxIterations: Int = 25,
        maxWallClockMs: Double = 10 * 60 * 1000,
        maxDecisionCalls: Int = 50,
        maxInputTokens: Int? = 200_000,
        maxOutputTokens: Int? = 50_000
    ) {
        self.maxIterations = maxIterations
        self.maxWallClockMs = maxWallClockMs
        self.maxDecisionCalls = maxDecisionCalls
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
    }

    var snapshot: (iterations: Int, toolCalls: Int, decisionCalls: Int, wallClockMs: Double, inputTokens: Int, outputTokens: Int) {
        (iterationsUsed, toolCalls, decisionCalls, Date().timeIntervalSince(startDate) * 1000, inputTokensUsed, outputTokensUsed)
    }

    /// Records one loop iteration. Returns warnings exactly once each.
    mutating func recordIteration() -> [BudgetWarning] {
        iterationsUsed += 1
        return checkWarnings()
    }

    mutating func recordToolCall() {
        toolCalls += 1
    }

    /// Records one decision-engine call. Returns warnings exactly once each.
    mutating func recordDecisionCall() -> [BudgetWarning] {
        decisionCalls += 1
        return checkWarnings()
    }

    /// Accumulates REPORTED token usage. Nil fields are skipped, never
    /// treated as zero — unknown stays unknown.
    mutating func recordUsage(_ usage: TokenUsage?) -> [BudgetWarning] {
        guard let usage, usage.isReported else { return [] }
        if let input = usage.inputTokens { inputTokensUsed += input }
        if let output = usage.outputTokens { outputTokensUsed += output }
        return checkWarnings()
    }

    /// Hard limits. Iteration/wall-clock always apply; token limits apply
    /// only when set AND usage was actually reported (counters stay 0
    /// otherwise, so an unset-or-unknown budget can never halt a run).
    /// Iterations use strict overrun: the loop bound already runs exactly
    /// maxIterations rounds, so `>=` here would eat the final round.
    func exceededReason() -> BudgetExceededReason? {
        if iterationsUsed > maxIterations { return .iterations }
        if Date().timeIntervalSince(startDate) * 1000 >= maxWallClockMs { return .wallClock }
        if let max = maxInputTokens, inputTokensUsed >= max { return .inputTokens }
        if let max = maxOutputTokens, outputTokensUsed >= max { return .outputTokens }
        return nil
    }

    private mutating func checkWarnings() -> [BudgetWarning] {
        var warnings: [BudgetWarning] = []
        if !warnedIterations, Double(iterationsUsed) >= Double(maxIterations) * Self.warnFraction {
            warnedIterations = true
            warnings.append(.iterationsHigh(used: iterationsUsed, max: maxIterations))
        }
        let elapsedMs = Date().timeIntervalSince(startDate) * 1000
        if !warnedWallClock, elapsedMs >= maxWallClockMs * Self.warnFraction {
            warnedWallClock = true
            warnings.append(.wallClockHigh(elapsedMs: elapsedMs, maxMs: maxWallClockMs))
        }
        if !warnedDecisionCalls, Double(decisionCalls) >= Double(maxDecisionCalls) * Self.warnFraction {
            warnedDecisionCalls = true
            warnings.append(.decisionCallsHigh(used: decisionCalls, max: maxDecisionCalls))
        }
        if let max = maxInputTokens, !warnedInputTokens, Double(inputTokensUsed) >= Double(max) * Self.warnFraction {
            warnedInputTokens = true
            warnings.append(.inputTokensHigh(used: inputTokensUsed, max: max))
        }
        if let max = maxOutputTokens, !warnedOutputTokens, Double(outputTokensUsed) >= Double(max) * Self.warnFraction {
            warnedOutputTokens = true
            warnings.append(.outputTokensHigh(used: outputTokensUsed, max: max))
        }
        return warnings
    }
}

/// Token estimator. Outputs are explicitly labeled estimates for the
/// compaction planner's early-hint path ONLY — never budget truth.
/// Different tokenizers disagree wildly; do not compare estimates
/// against hard caps.
enum TokenEstimator {
    /// Rough input-size estimate in tokens. Labeled, heuristic, replaceable.
    static func estimatedInputTokens(for messages: [LLMMessage]) -> Int {
        let bytes = messages.reduce(0) { $0 + $1.content.utf8.count }
        return bytes / 4
    }
}
