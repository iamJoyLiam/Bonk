//  AgentState.swift
//  Bonk
//
//  Phase 1 agent state skeleton: the single owned state for one agent run.
//  Owned and mutated by AgentRuntime only — DecisionEngine, TerminationGuard,
//  and views must read snapshots, never keep their own implicit copies.
//  Most fields start empty; consumers arrive in Phase 2+. Zero behavior
//  change: nothing reads this state to alter execution in Phase 1.

import Foundation

/// One executed tool step. `outputSummary` is truncated display text, never
/// the full transcript (see AgentObservation for bounded context).
struct AgentStepState: Sendable, Equatable {
    let tool: String
    let normalizedKey: String
    let exitCode: Int32
    let outputSummary: String
    let timestamp: Date

    init(tool: String, normalizedKey: String, exitCode: Int32, outputSummary: String, timestamp: Date = Date()) {
        self.tool = tool
        self.normalizedKey = normalizedKey
        self.exitCode = exitCode
        self.outputSummary = outputSummary
        self.timestamp = timestamp
    }
}

/// One bounded observation (model-visible context excerpt). Content is
/// truncated at insert time so the state can never grow into a transcript.
struct AgentObservation: Sendable, Equatable {
    enum Kind: String, Sendable {
        case toolOutput
        case userMessage
        case systemNote
    }

    let kind: Kind
    let text: String
    let timestamp: Date

    static let maxTextLength = 500
    static let maxObservations = 10

    init(kind: Kind, text: String, timestamp: Date = Date()) {
        self.kind = kind
        self.text = String(text.prefix(Self.maxTextLength))
        self.timestamp = timestamp
    }
}

/// Progress counters derived from steps. Success/failure here means tool
/// exit status, not goal achievement (that judgment is Phase 3+).
struct AgentProgressState: Sendable, Equatable {
    var completedSteps = 0
    var failedSteps = 0
    var lastExitCode: Int32?
}

/// Budget counters. Token fields stay nil until the model gateway exposes
/// real usage — Phase 1 never estimates or invents token counts.
struct AgentBudgetState: Sendable, Equatable {
    var iterationsUsed = 0
    var toolCalls = 0
    var decisionCalls = 0
    var wallClockMs: Double = 0
    var inputTokens: Int?
    var outputTokens: Int?
}

/// Phase-2 seam (unused in Phase 1): explicit fold verdict type so gate()
/// can never become a second PermissionPolicy. Kept here so the boundary
/// is visible before any evaluator exists.
enum ConfirmationDisposition: Sendable, Equatable {
    case keepConfirmation
    case foldConfirmation
}

/// Single owned state for one agent run.
struct AgentState: Sendable, Equatable {
    var goal: String?
    var steps: [AgentStepState] = []
    var observations: [AgentObservation] = []
    var progress = AgentProgressState()
    var budget = AgentBudgetState()

    mutating func appendStep(_ step: AgentStepState) {
        steps.append(step)
        if step.exitCode == 0 {
            progress.completedSteps += 1
        } else {
            progress.failedSteps += 1
        }
        progress.lastExitCode = step.exitCode
    }

    mutating func appendObservation(_ observation: AgentObservation) {
        observations.append(observation)
        if observations.count > AgentObservation.maxObservations {
            observations.removeFirst(observations.count - AgentObservation.maxObservations)
        }
    }
}
