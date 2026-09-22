//  AgentBudgetController.swift
//  Bonk
//
//  Phase 1 budget skeleton: the ONLY budget source for AgentRuntime.
//  Counts iterations, tool calls, decision calls, and wall-clock time.
//  Phase 1 emits warnings only (trace + log) — it never terminates, throttles,
//  or otherwise changes execution. Enforcement is Phase 5.

import Foundation
import os

/// Budget warning. Advisory in Phase 1: observed via trace, never enforced.
enum BudgetWarning: Sendable, Equatable {
    case iterationsHigh(used: Int, max: Int)
    case wallClockHigh(elapsedMs: Double, maxMs: Double)
    case decisionCallsHigh(used: Int, max: Int)
}

/// Sole budget keeper for one agent run. Value type owned by AgentRuntime;
/// mutate only from the driving task.
struct AgentBudgetController: Sendable {
    var maxIterations: Int
    var maxWallClockMs: Double
    var maxDecisionCalls: Int

    private var iterationsUsed = 0
    private var toolCalls = 0
    private var decisionCalls = 0
    private var startDate = Date()
    private var warnedIterations = false
    private var warnedWallClock = false
    private var warnedDecisionCalls = false

    private static let warnFraction = 0.8

    init(maxIterations: Int = 25, maxWallClockMs: Double = 10 * 60 * 1000, maxDecisionCalls: Int = 50) {
        self.maxIterations = maxIterations
        self.maxWallClockMs = maxWallClockMs
        self.maxDecisionCalls = maxDecisionCalls
    }

    var snapshot: (iterations: Int, toolCalls: Int, decisionCalls: Int, wallClockMs: Double) {
        (iterationsUsed, toolCalls, decisionCalls, Date().timeIntervalSince(startDate) * 1000)
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
        return warnings
    }
}
