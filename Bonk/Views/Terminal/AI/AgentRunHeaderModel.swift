//  AgentRunHeaderModel.swift
//  Bonk
//
//  Tier B run header model: pure snapshot formatting for the agent run
//  header (Codex-style collapsible). No view code, fully unit-testable.
//  Token display rule: reported numbers render grouped, unknown renders
//  "—" — estimates never appear here.

import Foundation

/// Snapshot Purveyors feed this from AgentState + engine snapshots.
struct AgentRunHeaderModel: Equatable {
    let goal: String?
    let steps: Int
    let toolCalls: Int
    let decisionCalls: Int
    let inputTokens: Int?
    let outputTokens: Int?
    let providerName: String?
    let routeSource: String?
    let maxIterations: Int

    static func current(
        state: AgentState,
        providerName: String?,
        routeSource: String?,
        maxIterations: Int
    ) -> Self {
        AgentRunHeaderModel(
            goal: state.goal,
            steps: state.progress.completedSteps + state.progress.failedSteps,
            toolCalls: state.budget.toolCalls,
            decisionCalls: state.budget.decisionCalls,
            inputTokens: state.budget.inputTokens,
            outputTokens: state.budget.outputTokens,
            providerName: providerName,
            routeSource: routeSource,
            maxIterations: maxIterations
        )
    }

    /// Reported token rendering: grouped digits, or "—" when unknown.
    /// Zero with no report reads as unknown — providers that report send
    /// nonzero input on the first turn.
    static func tokensText(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        return value.formatted(.number.grouping(.automatic))
    }

    /// Collapsed one-liner facts (provider/source/steps/tools/tokens).
    /// Assembled by the view from localized labels + these segments.
    var tokenTotalText: String {
        let total = (inputTokens ?? 0) + (outputTokens ?? 0)
        return total > 0 ? total.formatted(.number.grouping(.automatic)) : "—"
    }
}
