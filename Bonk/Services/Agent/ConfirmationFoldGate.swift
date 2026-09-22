//  ConfirmationFoldGate.swift
//  Bonk
//
//  Shared fold-gate orchestration for the Runtime and legacy plan paths.
//  Takes an already-eligible confirmation, asks the engine fold/keep,
//  and traces requested/resolved/fallback. Never fails open: engine
//  errors fall back to keeping the confirmation dialog.

import Foundation

/// Gate input facts. Normalized command only — raw commands, prompts,
/// and transcripts never cross this boundary.
struct FoldGateFacts: Sendable {
    let tool: String
    let normalizedCommand: String
    let safetyLevel: String
    let accessMode: String
    let semanticTags: String
    let previousUserDecision: String
    let sameCommandOccurrences: Int
    let iteration: Int
}

enum ConfirmationFoldGate {
    /// Asks the engine fold/keep for an eligible confirmation.
    /// Returns the disposition plus gate latency for trace/budget use.
    static func evaluate(
        engine: any DecisionEngine,
        facts: FoldGateFacts,
        threshold: Double,
        task: String
    ) async -> (disposition: ConfirmationDisposition, latencyMs: Double) {
        trace(kind: .decisionRequested, engine: engine.engineName, task: task, result: "fold-confirmation")
        let start = Date()
        do {
            let decision = try await engine.gate(
                question: "fold-confirmation",
                context: DecisionContext(
                    localConfidence: 1.0,
                    decisionThreshold: threshold,
                    facts: [
                        "tool": facts.tool,
                        "normalizedCommand": facts.normalizedCommand,
                        "safetyLevel": facts.safetyLevel,
                        "accessMode": facts.accessMode,
                        "semanticTags": facts.semanticTags,
                        "previousUserDecision": facts.previousUserDecision,
                        "sameCommandOccurrences": "\(facts.sameCommandOccurrences)",
                        "iteration": "\(facts.iteration)",
                    ]
                )
            )
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let disposition: ConfirmationDisposition = decision.shouldProceed ? .foldConfirmation : .keepConfirmation
            trace(
                kind: .decisionResolved, engine: engine.engineName, task: task,
                latencyMs: latencyMs, result: disposition == .foldConfirmation ? "fold" : "keep"
            )
            return (disposition, latencyMs)
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            trace(
                kind: .decisionFallback, engine: engine.engineName, task: task,
                latencyMs: latencyMs, success: false, result: "gate-error"
            )
            return (.keepConfirmation, latencyMs)
        }
    }

    private static func trace(
        kind: AgentTraceKind, engine: String, task: String,
        latencyMs: Double = 0, success: Bool = true, result: String = ""
    ) {
        Task {
            await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
                kind: kind, engine: engine, task: task,
                latencyMs: latencyMs, success: success, result: result
            ))
        }
    }
}
