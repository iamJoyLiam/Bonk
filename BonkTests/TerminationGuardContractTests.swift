//  TerminationGuardContractTests.swift
//  BonkTests
//
//  Contract tests for TerminationGuard (P1.4).
//  Validates anti-loop fingerprinting and loop termination policy.
//

import Testing
import Foundation
@testable import Bonk

@Suite("TerminationGuard Contract Tests")
@MainActor
struct TerminationGuardContractTests {

    @Test("First execution of a tool proceeds normally")
    func firstExecutionProceeds() {
        let guardTracker = TerminationGuard()
        let result = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"ls\"}",
            output: "file1 file2"
        )
        #expect(result == .proceed)
    }

    @Test("Consecutive duplicate execution warns then terminates loop")
    func consecutiveDuplicateWarnsThenTerminates() {
        let guardTracker = TerminationGuard()
        
        let r1 = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker images\"}",
            output: "IMAGE REPOSITORY TAG"
        )
        #expect(r1 == .proceed)

        let r2 = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker images\"}",
            output: "IMAGE REPOSITORY TAG"
        )
        #expect(r2 == .warnDuplicate(toolName: "execute_command"))

        let r3 = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker images\"}",
            output: "IMAGE REPOSITORY TAG"
        )
        if case .terminateLoop = r3 {
            #expect(true)
        } else {
            Issue.record("Expected terminateLoop on consecutive duplicate execution")
        }
    }

    @Test("Repeated identical command without progress across session terminates")
    func repeatedCommandWithoutProgressTerminates() {
        let guardTracker = TerminationGuard()

        _ = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker ps\"}",
            output: "CONTAINER ID"
        )
        _ = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"date\"}",
            output: "2026-09-04"
        )
        _ = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker ps\"}",
            output: "CONTAINER ID"
        )
        _ = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"uname -a\"}",
            output: "Darwin"
        )
        let r5 = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker ps\"}",
            output: "CONTAINER ID"
        )
        if case .terminateLoop = r5 {
            #expect(true)
        } else {
            Issue.record("Expected terminateLoop when same tool runs 3 times without progress")
        }
    }

    @Test("Commands with changing output proceed as progress is made")
    func changingOutputProceeds() {
        let guardTracker = TerminationGuard()

        let r1 = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker ps\"}",
            output: "CONTAINER ID 1"
        )
        #expect(r1 == .proceed)

        let r2 = guardTracker.recordAndEvaluate(
            toolName: "execute_command",
            arguments: "{\"command\":\"docker ps\"}",
            output: "CONTAINER ID 1\nCONTAINER ID 2"
        )
        #expect(r2 == .proceed)
    }
}
