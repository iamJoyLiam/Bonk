//
//  AgentTierBTests.swift
//  BonkTests
//
//  Tier B acceptance: run header model formatting (unknown tokens render
//  "—", never estimates) and typed error plumbing (code travels from
//  event to message; visuals stay view-side).
//

@testable import Bonk
import Foundation
import Testing

@Suite("Run header model")
struct RunHeaderModelTests {
    private func state() -> AgentState {
        var state = AgentState(goal: "check uptime")
        state.appendStep(AgentStepState(tool: "run_command", normalizedKey: "uptime", exitCode: 0, outputSummary: "ok"))
        state.budget.toolCalls = 3
        state.budget.decisionCalls = 1
        state.budget.inputTokens = 8_421
        state.budget.outputTokens = 120
        return state
    }

    @Test("Model assembles counts from state and snapshots")
    func assembly() {
        let model = AgentRunHeaderModel.current(
            state: state(), providerName: "openai", routeSource: "deterministicSingle", maxIterations: 25
        )
        #expect(model.goal == "check uptime")
        #expect(model.steps == 1)
        #expect(model.toolCalls == 3)
        #expect(model.decisionCalls == 1)
        #expect(model.providerName == "openai")
        #expect(model.tokenTotalText.filter(\.isNumber) == "8541")
    }

    @Test("Unknown tokens render as an em dash, never zero or estimates")
    func unknownTokens() {
        #expect(AgentRunHeaderModel.tokensText(nil) == "—")
        #expect(AgentRunHeaderModel.tokensText(0) == "—")
        #expect(AgentRunHeaderModel.tokensText(8_421).filter(\.isNumber) == "8421")
        var state = AgentState(goal: nil)
        let model = AgentRunHeaderModel.current(state: state, providerName: nil, routeSource: nil, maxIterations: 25)
        #expect(model.tokenTotalText == "—")
        #expect(model.providerName == nil)
    }
}

@Suite("Typed errors")
struct TypedErrorTests {
    @Test("Error code travels from event to message, defaulting nil")
    func plumbing() {
        let plain = AgentMessage(role: .system, content: "x")
        #expect(plain.errorCode == nil)
        let coded = AgentMessage(role: .system, content: "x", errorCode: .budgetExceeded)
        #expect(coded.errorCode == .budgetExceeded)
    }

    @Test("All codes are representable for the transcript")
    func codes() {
        for code in [AgentErrorCode.progressStall, .budgetExceeded, .modelFailure, .generic] as [AgentErrorCode] {
            #expect(!code.rawValue.isEmpty)
        }
    }
}
