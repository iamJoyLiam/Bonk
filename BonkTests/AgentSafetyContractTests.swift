//  AgentSafetyContractTests.swift
//  BonkTests
//
//  End-to-end integration safety contract tests for Agent Runtime (P1.5).
//  Validates the full safety matrix: Intent -> SafetyLevel -> OutputGuard -> TerminationGuard.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Agent Safety Contract Tests")
@MainActor
struct AgentSafetyContractTests {

    @Test("Context mention alone does not trigger tool loop execution")
    func contextMentionAloneDoesNotExecute() {
        let intent = UserIntent.parse(rawInput: "@history", defaultExecutionRequested: true)
        #expect(!intent.executionRequested)
        #expect(intent.contextReferences.contains(.history))
    }

    @Test("Inspection commands are L1 and execute without elevation")
    func inspectionCommandsAreL1() {
        let level = CommandSafety.classifyLevel("docker ps")
        #expect(level == .l1SafeInspection)
    }

    @Test("Mutating commands are L2 and require approval under supervised mode")
    func mutatingCommandsAreL2() {
        let level = CommandSafety.classifyLevel("mkdir -p /tmp/test")
        #expect(level == .l2StateMutation)
    }

    @Test("Dangerous commands are L3 and always require approval")
    func dangerousCommandsAreL3() {
        let level = CommandSafety.classifyLevel("rm -rf build")
        #expect(level == .l3HighRisk)
    }

    @Test("Privilege escalation and fork bombs are L4 and strictly blocked")
    func privilegeEscalationIsL4Blocked() {
        let level = CommandSafety.classifyLevel(":(){ :|:& };:")
        #expect(level == .l4Critical)
    }

    @Test("OutputGuard enforces 32KB and line limits to protect context")
    func outputGuardEnforcesLimits() {
        let lines = (1...500).map { "Line \($0)" }.joined(separator: "\n")
        let guarded = OutputGuard.guardOutput(lines)
        #expect(guarded.isTruncated)
        #expect(guarded.content.contains("... [Output truncated:"))
        #expect(guarded.content.contains("Line 1"))
        #expect(guarded.content.contains("Line 500"))
    }

    @Test("TerminationGuard halts agent loop on repetitive tool invocations")
    func terminationGuardHaltsRepetitiveLoop() {
        let guardTracker = TerminationGuard()
        _ = guardTracker.recordAndEvaluate(toolName: "run", arguments: "{\"cmd\":\"ps\"}", output: "1")
        _ = guardTracker.recordAndEvaluate(toolName: "run", arguments: "{\"cmd\":\"ps\"}", output: "1")
        let finalEval = guardTracker.recordAndEvaluate(toolName: "run", arguments: "{\"cmd\":\"ps\"}", output: "1")
        
        if case .terminateLoop = finalEval {
            #expect(true)
        } else {
            Issue.record("Expected terminateLoop on consecutive duplicates")
        }
    }
}
