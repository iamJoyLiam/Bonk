//  AgentTraceEvent.swift
//  Bonk
//
//  Phase 1 agent observability: typed lifecycle events for routing,
//  decisions, budget warnings, and confirmation folding. Facts only —
//  never command text, prompts, or transcripts (audit size + secrets).

import Foundation

/// Agent lifecycle event kinds. Values are stable strings for logs/metrics.
enum AgentTraceKind: String, Sendable {
    case decisionRequested = "decision.requested"
    case decisionResolved = "decision.resolved"
    case decisionFallback = "decision.fallback"
    case decisionSkipped = "decision.skipped"
    case budgetWarning = "budget.warning"
    case routerSelected = "router.selected"
    case routerFallback = "router.fallback"
    case confirmationFoldable = "confirmation.foldable"
}

/// One agent lifecycle event. `result` is a short machine-readable outcome
/// (e.g. "deterministicSingle", "fallback-no-route"); free-form user data
/// must never be stored here.
struct AgentTraceEvent: Sendable, Equatable {
    let timestamp: Date
    let kind: AgentTraceKind
    /// Engine label ("deterministic"/"jev"/"laya") or "router"/"budget"/"runtime".
    let engine: String
    /// Task label ("agentExecute"/"agentPlan"/...). Caller-defined.
    let task: String
    /// Wall-clock cost in milliseconds, 0 when not applicable.
    let latencyMs: Double
    /// True when the step succeeded without fallback.
    let success: Bool
    /// Schema version of the input facts ("1" for Phase 1).
    let factsVersion: String
    let result: String

    init(
        kind: AgentTraceKind,
        engine: String,
        task: String,
        latencyMs: Double = 0,
        success: Bool = true,
        factsVersion: String = AgentTraceEvent.currentFactsVersion,
        result: String = "",
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.engine = engine
        self.task = task
        self.latencyMs = latencyMs
        self.success = success
        self.factsVersion = factsVersion
        self.result = result
    }

    static let currentFactsVersion = "1"
}

extension DecisionTraceRecorder {
    private static var agentCapacity: Int { 200 }

    /// Fire-and-forget agent event recording. Never on a hot path directly —
    /// callers must wrap in Task when inside the agent loop.
    func recordAgentEvent(_ event: AgentTraceEvent) {
        agentEvents.append(event)
        if agentEvents.count > Self.agentCapacity {
            agentEvents.removeFirst(agentEvents.count - Self.agentCapacity)
        }
    }

    func recentAgentEvents(limit: Int = 20) -> [AgentTraceEvent] {
        Array(agentEvents.suffix(limit))
    }

    func agentEventCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for event in agentEvents {
            counts[event.kind.rawValue, default: 0] += 1
        }
        return counts
    }

    func resetAgentEvents() {
        agentEvents = []
    }
}
