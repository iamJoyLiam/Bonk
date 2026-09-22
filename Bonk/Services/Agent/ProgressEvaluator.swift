//  ProgressEvaluator.swift
//  Bonk
//
//  Phase 3 semantic no-progress detection. Three tiers:
//
//  Tier 0 (exact repeats): owned by TerminationGuard, untouched here.
//  Tier 1 (cheap diff): Jaccard similarity over output lines plus exit-code
//    change, computed for every non-terminal step. Suspicious = high
//    similarity with no exit change, twice in a row.
//  Tier 2 (semantic score): only inside the suspicious window, the engine
//    scores PROGRESS (not output similarity) from a bounded summary.
//    Raw transcripts never cross into the engine — only the summary.
//
//  Embedding similarity stays deferred: Tier 1 + Tier 2 cover the loop
//  patterns seen so far; revisit when calibration data shows Tier 1
//  missing real stalls.

import Foundation

/// One step for the progress summary. `result` is a bounded excerpt, not
/// the full output.
struct ProgressStepSummary: Sendable, Equatable {
    let tool: String
    let action: String
    let exitCode: Int32
    let result: String

    static let maxResultLength = 120

    init(tool: String, action: String, exitCode: Int32, output: String) {
        self.tool = tool
        self.action = action
        self.exitCode = exitCode
        self.result = String(output.prefix(Self.maxResultLength))
    }
}

/// Bounded progress summary handed to the engine. Answers "is the agent
/// moving toward the goal", never "do these outputs look alike".
struct RecentProgressSummary: Sendable, Equatable {
    let goal: String
    let lastSteps: [ProgressStepSummary]
    let failureStreak: Int

    static let maxSteps = 3
}

/// Tier-1 cheap diff between consecutive outputs.
struct ProgressSignal: Sendable, Equatable {
    /// Jaccard similarity over output lines in [0, 1]. 1.0 when both empty.
    let similarity: Double
    let addedLines: Int
    let removedLines: Int
    let exitCodeChanged: Bool
}

enum ProgressVerdict: Sendable, Equatable {
    case `continue`
    case breakLoop(reason: String)
}

/// Semantic progress evaluator. Value type owned by AgentRuntime; mutate
/// only from the driving task. Thresholds are constants pending
/// calibration data — they are documented guesses, not fitted values.
struct ProgressEvaluator: Sendable {
    /// Tier-1 bar: at/above this similarity (with no exit change) counts
    /// as one suspicious observation.
    var similarityThreshold = 0.9
    /// Suspicious observations in a row before Tier-2 judgment runs.
    var suspiciousToJudge = 2
    /// Tier-2 bar: progress scores at/below this break the loop.
    var noProgressThreshold = 0.3

    private var lastOutput: String?
    private var lastExitCode: Int32?
    private var consecutiveSuspicious = 0
    private var recent: [ProgressStepSummary] = []
    private var failureStreak = 0

    enum Assessment: Sendable, Equatable {
        case `continue`
        case needsJudgment(option: DecisionOption, context: DecisionContext)

        // DecisionContext is intentionally not Equatable (facts are caller-
        // defined); compare the fields Tier 2 actually consumes.
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.continue, .continue):
                return true
            case let (.needsJudgment(lo, lc), .needsJudgment(ro, rc)):
                return lo == ro
                    && lc.localConfidence == rc.localConfidence
                    && lc.decisionThreshold == rc.decisionThreshold
                    && lc.facts == rc.facts
            default:
                return false
            }
        }
    }

    /// Pure Tier-1 diff. Exposed for tests.
    static func diffSignal(current: String, previous: String, exitCodeChanged: Bool) -> ProgressSignal {
        let currentLines = Set(current.components(separatedBy: "\n"))
        let previousLines = Set(previous.components(separatedBy: "\n"))
        let unionCount = currentLines.union(previousLines).count
        let similarity = unionCount > 0
            ? Double(currentLines.intersection(previousLines).count) / Double(unionCount)
            : 1.0
        return ProgressSignal(
            similarity: similarity,
            addedLines: currentLines.subtracting(previousLines).count,
            removedLines: previousLines.subtracting(currentLines).count,
            exitCodeChanged: exitCodeChanged
        )
    }

    /// Observes one executed step. Returns a judgment request only inside
    /// the suspicious window; every other step continues silently.
    mutating func observe(
        callId: String,
        tool: String,
        actionKey: String,
        exitCode: Int32,
        output: String,
        goal: String,
        iteration: Int
    ) -> Assessment {
        // Tier 1: cheap diff against the previous step, if any.
        var signal: ProgressSignal?
        if let previous = lastOutput {
            signal = Self.diffSignal(current: output, previous: previous, exitCodeChanged: exitCode != lastExitCode)
        }
        lastOutput = output
        lastExitCode = exitCode

        let summary = ProgressStepSummary(tool: tool, action: actionKey, exitCode: exitCode, output: output)
        recent.append(summary)
        if recent.count > RecentProgressSummary.maxSteps {
            recent.removeFirst(recent.count - RecentProgressSummary.maxSteps)
        }
        if exitCode == 0 {
            failureStreak = 0
        } else {
            failureStreak += 1
        }

        guard let signal else {
            // First observation establishes the baseline; nothing to compare.
            return .continue
        }
        if signal.similarity >= similarityThreshold, !signal.exitCodeChanged {
            consecutiveSuspicious += 1
        } else {
            consecutiveSuspicious = 0
        }
        guard consecutiveSuspicious >= suspiciousToJudge else { return .continue }
        consecutiveSuspicious = 0

        let stepsText = recent
            .map { "\($0.tool):\($0.action):exit\($0.exitCode):\($0.result)" }
            .joined(separator: " | ")
        let option = DecisionOption(
            id: callId,
            label: actionKey,
            localScore: exitCode == 0 ? 1.0 : 0.0
        )
        let context = DecisionContext(
            localConfidence: signal.similarity,
            decisionThreshold: noProgressThreshold,
            facts: [
                "goal": goal,
                "recentSteps": stepsText,
                "failureStreak": "\(failureStreak)",
                "similarity": String(format: "%.3f", signal.similarity),
                "iteration": "\(iteration)",
            ]
        )
        return .needsJudgment(option: option, context: context)
    }

    /// Records a Tier-2 judgment. Low progress breaks the loop; anything
    /// else continues (the window already reset at judgment time).
    func recordJudgment(score: Double) -> ProgressVerdict {
        guard score <= noProgressThreshold else { return .continue }
        return .breakLoop(reason: "No meaningful progress detected (progress score \(String(format: "%.2f", score))).")
    }
}
