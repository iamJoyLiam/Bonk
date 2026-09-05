//  UserIntentContractTests.swift
//  BonkTests
//
//  Contract tests for UserIntent (P1.1).
//  Validates separation of context mentions from execution requests.
//

import Testing
@testable import Bonk

@Suite("UserIntent Contract Tests")
struct UserIntentContractTests {

    @Test("Bare context mention does not request execution")
    func bareContextMentionDoesNotRequestExecution() {
        let intent = UserIntent.parse(rawInput: "@history", defaultExecutionRequested: true)
        #expect(intent.contextReferences == [.history])
        #expect(intent.prompt.isEmpty)
        #expect(intent.executionRequested == false)
    }

    @Test("Multiple context mentions without prompt does not request execution")
    func multipleContextMentionsWithoutPrompt() {
        let intent = UserIntent.parse(rawInput: "@history @terminal", defaultExecutionRequested: true)
        #expect(Set(intent.contextReferences) == Set([.history, .terminal]))
        #expect(intent.prompt.isEmpty)
        #expect(intent.executionRequested == false)
    }

    @Test("Context mention with actionable prompt requests execution")
    func contextMentionWithActionablePrompt() {
        let intent = UserIntent.parse(
            rawInput: "@history 查找最近执行过的 docker 命令",
            defaultExecutionRequested: true
        )
        #expect(intent.contextReferences == [.history])
        #expect(intent.prompt == "查找最近执行过的 docker 命令")
        #expect(intent.executionRequested == true)
    }

    @Test("Normal prompt without mentions requests execution")
    func normalPromptWithoutMentions() {
        let intent = UserIntent.parse(
            rawInput: "查看系统当前内存使用情况",
            defaultExecutionRequested: true
        )
        #expect(intent.contextReferences.isEmpty)
        #expect(intent.prompt == "查看系统当前内存使用情况")
        #expect(intent.executionRequested == true)
    }

    @Test("Default non-execution preserves false even with prompt")
    func defaultNonExecutionPreservesFalse() {
        let intent = UserIntent.parse(
            rawInput: "查看系统当前内存使用情况",
            defaultExecutionRequested: false
        )
        #expect(intent.executionRequested == false)
    }

    @Test("Pure greeting inputs do not trigger command execution")
    func pureGreetingsDoNotTriggerExecution() {
        let g1 = UserIntent.parse(rawInput: "你好", defaultExecutionRequested: true)
        #expect(g1.isConversational == true)
        #expect(g1.executionRequested == false)

        let g2 = UserIntent.parse(rawInput: "你好！", defaultExecutionRequested: true)
        #expect(g2.isConversational == true)
        #expect(g2.executionRequested == false)

        let g3 = UserIntent.parse(rawInput: "hello", defaultExecutionRequested: true)
        #expect(g3.isConversational == true)
        #expect(g3.executionRequested == false)

        let g4 = UserIntent.parse(rawInput: "在吗", defaultExecutionRequested: true)
        #expect(g4.isConversational == true)
        #expect(g4.executionRequested == false)

        let mixed = UserIntent.parse(rawInput: "你好，查看系统当前内存使用情况", defaultExecutionRequested: true)
        #expect(mixed.isConversational == false)
        #expect(mixed.executionRequested == true)
    }
}

