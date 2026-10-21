//
//  AgentMessageHistoryTests.swift
//  BonkTests
//
//  Covers the conversation-scoped model history (task 001-A).
//
//  The gap this closes: the agent loop rebuilt `[system, user]` on every run,
//  so the model could not see what it had already said or run. These tests
//  hold that closed at the production decision boundary — the message array
//  the runtime actually hands to the model gateway — rather than at the
//  structure of the history object.
//
//  Four patterns, per AGENTS.md:
//    1. behavioural — the second turn's request carries the first turn
//    2. pure        — the projection rules, exercised without a runtime
//    3. wiring      — the production agent path binds and injects the history
//    4. mutation    — removing the recording breaks the behavioural test
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("Agent Message History Tests")
struct AgentMessageHistoryTests {

    // MARK: - Mocks

    /// Gateway that records every request it is handed.
    ///
    /// The request array is the production decision boundary for this feature:
    /// it is literally what the model would receive. Asserting on the history
    /// object instead would pass even if the runtime never used it.
    final class CapturingModelGateway: AgentModelGateway, @unchecked Sendable {
        private struct State {
            var responses: [LLMResponse]
            var requests: [[LLMMessage]] = []
        }
        private let state = OSAllocatedUnfairLock(uncheckedState: State(responses: []))

        init(responses: [LLMResponse]) {
            state.withLock { $0.responses = responses }
        }

        var capturedRequests: [[LLMMessage]] {
            state.withLock { $0.requests }
        }

        func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
            state.withLock { state in
                state.requests.append(messages)
                guard !state.responses.isEmpty else { return LLMResponse(text: "mock default") }
                return state.responses.removeFirst()
            }
        }

        func stream(messages: [LLMMessage]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { continuation in continuation.finish() }
        }
    }

    private static func toolCall(id: String, command: String) -> LLMToolCall {
        LLMToolCall(
            id: id,
            name: "run_command",
            argumentsJSON: "{\"command\":\"\(command)\"}"
        )
    }

    /// Drain a runtime's event stream.
    private func run(
        _ runtime: AgentRuntime,
        input: String,
        command output: String = "ok"
    ) async {
        let stream = runtime.run(input: input) { _, _ in (output, 0) }
        for await _ in stream {}
    }

    // MARK: - 1. Behavioural

    @Test("A second turn starts from the first turn's messages")
    func secondTurnCarriesTheFirstTurn() async {
        let gateway = CapturingModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [Self.toolCall(id: "call-1", command: "uptime")]),
            LLMResponse(text: "up 3 days"),
        ])
        let history = ConversationMessageHistory()
        let conversationID = UUID()
        history.bind(to: conversationID)

        // Turn one: the model asks for a command and then answers.
        let first = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(first, input: "how long has it been up?", command: "up 3 days")

        // Turn two: a brand new runtime, same conversation.
        let second = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(second, input: "and the memory?")

        let requests = gateway.capturedRequests
        #expect(requests.count == 3, "expected two requests for turn one and one for turn two")

        let secondTurn = requests[2]

        // The first turn's user message.
        #expect(secondTurn.contains { $0.role == .user && $0.content == "how long has it been up?" },
                "the second turn lost the first user message")

        // The first turn's assistant tool call, with its call id.
        #expect(secondTurn.contains {
            $0.role == .assistant && ($0.toolCalls?.contains { $0.id == "call-1" } ?? false)
        }, "the second turn lost the first assistant tool call")

        // The first turn's tool result, linked by call id.
        #expect(secondTurn.contains { $0.role == .tool && $0.toolCallID == "call-1" },
                "the second turn lost the first tool result")

        // The first turn's closing answer.
        #expect(secondTurn.contains { $0.role == .assistant && $0.content == "up 3 days" },
                "the second turn lost the first turn's conclusion")

        // The new turn is last, and the system prompt is still first.
        #expect(secondTurn.first?.role == .system, "the system prompt must stay at the head")
        #expect(secondTurn.last?.content == "and the memory?")
    }

    @Test("The system's closing answer is remembered, its internal instruction is not")
    func synthesisInstructionIsNotRemembered() async {
        let gateway = CapturingModelGateway(responses: [
            LLMResponse(text: "", toolCalls: [Self.toolCall(id: "call-1", command: "uptime")]),
            LLMResponse(text: "the answer"),
        ])
        let history = ConversationMessageHistory()
        history.bind(to: UUID())

        // maxIterations 1 forces the loop to exit and run the final synthesis.
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            maxIterations: 1,
            messageHistory: history
        )
        await run(runtime, input: "look around")

        let stored = history.load()
        #expect(stored.contains { $0.role == .assistant && $0.content == "the answer" },
                "the conclusion must survive for the next turn")
        #expect(!stored.contains { $0.role == .user && $0.content.contains("All terminal inspection commands") },
                "the internal synthesis instruction is not something the user said")
    }

    @Test("A conversation does not inherit another conversation's turns")
    func conversationsAreIsolated() async {
        let gateway = CapturingModelGateway(responses: [
            LLMResponse(text: "answer for the first chat"),
        ])
        let history = ConversationMessageHistory()

        history.bind(to: UUID())
        let first = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(first, input: "secret from chat one")

        // Switching to a different conversation must not surface chat one's
        // turns.
        history.bind(to: UUID())
        let second = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(second, input: "hello")

        let requests = gateway.capturedRequests
        #expect(requests.count == 2)
        #expect(!requests[1].contains { $0.content.contains("secret from chat one") },
                "one conversation's turns leaked into another")
    }

    @Test("Coming back to a conversation finds its memory again")
    func returningToAConversationRestoresItsMemory() async {
        let gateway = CapturingModelGateway(responses: [
            LLMResponse(text: "answer"),
        ])
        let history = ConversationMessageHistory()
        let conversationID = UUID()

        history.bind(to: conversationID)
        let first = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(first, input: "remember the word banana")

        // Leave and come back.
        history.bind(to: UUID())
        history.bind(to: conversationID)

        let second = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(second, input: "what was the word?")

        let requests = gateway.capturedRequests
        #expect(requests[1].contains { $0.content.contains("banana") },
                "returning to a conversation must find its memory again")
    }

    @Test("An unkeyed run inherits nothing")
    func unkeyedRunHasNoMemory() async {
        let gateway = CapturingModelGateway(responses: [LLMResponse(text: "answer")])
        let history = ConversationMessageHistory()

        // No conversation bound at all.
        let runtime = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(runtime, input: "first")

        #expect(history.load().isEmpty,
                "a run with no conversation must not accumulate history to leak")
    }

    @Test("A reset clears what the model remembers")
    func resetClearsMemory() async {
        let gateway = CapturingModelGateway(responses: [LLMResponse(text: "answer")])
        let history = ConversationMessageHistory()
        history.bind(to: UUID())

        let first = AgentRuntime(
            modelGateway: gateway,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised),
            messageHistory: history
        )
        await run(first, input: "remember banana")
        #expect(!history.load().isEmpty)

        history.reset()
        #expect(history.load().isEmpty, "reset must clear the remembered turns")
    }

    // MARK: - 2. Pure: the projection rules

    @Test("Recording a tool call before its result does not lose the turn")
    func halfWrittenTurnSurvivesTheWrite() {
        // A turn is written in pieces: the assistant asks for a tool call, and
        // the result only arrives afterwards. If the store projected on every
        // write, the assistant half would read as an unanswered call and be
        // discarded — and the tool result would arrive to a turn that was
        // never there.
        let history = ConversationMessageHistory()
        history.bind(to: UUID())

        history.record(.user("check it"))
        history.record(LLMMessage(
            role: .assistant, content: "",
            toolCalls: [Self.toolCall(id: "call-1", command: "uptime")]
        ))

        // Read while the turn is still open: an unanswered tool call must not
        // be handed to a provider, which would reject the whole request.
        let openTurn = history.load()
        #expect(!openTurn.contains {
            $0.role == .assistant && ($0.toolCalls?.contains { $0.id == "call-1" } ?? false)
        }, "an unanswered tool call must not reach the provider")

        // The result arrives and pairs with the assistant half.
        history.record(LLMMessage(role: .tool, content: "up 3 days", toolCallID: "call-1"))

        let closedTurn = history.load()
        #expect(closedTurn.contains {
            $0.role == .assistant && ($0.toolCalls?.contains { $0.id == "call-1" } ?? false)
        }, "the assistant half must still be there once the result arrives")
        #expect(closedTurn.contains { $0.role == .tool && $0.toolCallID == "call-1" },
                "the tool result must not be orphaned")
    }

    @Test("validPrefix keeps a fully answered tool turn")
    func validPrefixKeepsAnsweredTurn() {
        let messages: [LLMMessage] = [
            .user("check it"),
            LLMMessage(role: .assistant, content: "", toolCalls: [Self.toolCall(id: "c1", command: "uptime")]),
            LLMMessage(role: .tool, content: "up 3 days", toolCallID: "c1"),
        ]
        let projected = AgentHistoryProjection.validPrefix(messages)
        #expect(projected.count == 3, "a complete turn must survive intact")
        #expect(projected.contains { $0.role == .tool && $0.toolCallID == "c1" })
    }

    @Test("validPrefix drops an assistant turn whose tool call was never answered")
    func validPrefixDropsUnansweredTurn() {
        // A run that stopped on a budget halt leaves the assistant turn open.
        let messages: [LLMMessage] = [
            .user("check it"),
            LLMMessage(role: .assistant, content: "", toolCalls: [Self.toolCall(id: "c1", command: "uptime")]),
        ]
        let projected = AgentHistoryProjection.validPrefix(messages)
        #expect(projected.count == 1, "an unanswered tool call must not be sent to the provider")
        #expect(projected.allSatisfy { $0.role != .assistant })
    }

    @Test("validPrefix drops the whole turn when only some calls were answered")
    func validPrefixDropsPartiallyAnsweredTurn() {
        let messages: [LLMMessage] = [
            LLMMessage(
                role: .assistant, content: "",
                toolCalls: [
                    Self.toolCall(id: "c1", command: "uptime"),
                    Self.toolCall(id: "c2", command: "df -h"),
                ]
            ),
            LLMMessage(role: .tool, content: "up 3 days", toolCallID: "c1"),
        ]
        let projected = AgentHistoryProjection.validPrefix(messages)
        #expect(projected.isEmpty,
                "a partially answered turn is invalid, and its result goes with it")
    }

    @Test("validPrefix drops a tool result with no matching call")
    func validPrefixDropsOrphanedToolResult() {
        let messages: [LLMMessage] = [
            .user("check it"),
            LLMMessage(role: .tool, content: "stray output", toolCallID: "nobody-asked"),
        ]
        let projected = AgentHistoryProjection.validPrefix(messages)
        #expect(projected.count == 1, "an orphaned tool result must not be sent")
        #expect(projected.allSatisfy { $0.role != .tool })
    }

    @Test("validPrefix never stores the system prompt")
    func validPrefixDropsSystemMessages() {
        let messages: [LLMMessage] = [
            .system("you are an agent"),
            .user("hello"),
        ]
        let projected = AgentHistoryProjection.validPrefix(messages)
        #expect(projected.count == 1)
        #expect(projected.allSatisfy { $0.role != .system })
    }

    @Test("boundedPrefix keeps the most recent turns and drops the oldest")
    func boundedPrefixKeepsRecentTurns() {
        var messages: [LLMMessage] = []
        for index in 0..<20 {
            messages.append(.user("turn \(index)"))
        }
        let bounded = AgentHistoryProjection.boundedPrefix(messages, maxCharacters: 200)
        #expect(bounded.count < messages.count, "the budget must actually bite")
        #expect(bounded.last?.content == "turn 19", "the newest turn must survive")
        #expect(!bounded.contains { $0.content == "turn 0" }, "the oldest turn must go")
    }

    @Test("boundedPrefix leaves a small history alone")
    func boundedPrefixKeepsSmallHistories() {
        let messages: [LLMMessage] = [.user("hello"), .user("world")]
        let bounded = AgentHistoryProjection.boundedPrefix(messages, maxCharacters: 100_000)
        #expect(bounded.count == 2)
    }

    @Test("boundedPrefix leaves no orphan behind when it cuts")
    func boundedPrefixCutsCleanly() {
        var messages: [LLMMessage] = []
        for index in 0..<10 {
            messages.append(
                LLMMessage(
                    role: .assistant, content: "",
                    toolCalls: [Self.toolCall(id: "c\(index)", command: "uptime")]
                )
            )
            messages.append(LLMMessage(role: .tool, content: "out", toolCallID: "c\(index)"))
        }
        let bounded = AgentHistoryProjection.boundedPrefix(messages, maxCharacters: 400)
        // Every surviving tool result must still have its assistant turn.
        var assistantIDs: Set<String> = []
        for message in bounded where message.role == .assistant {
            for call in message.toolCalls ?? [] {
                assistantIDs.insert(call.id)
            }
        }
        for message in bounded where message.role == .tool {
            #expect(assistantIDs.contains(message.toolCallID ?? ""),
                    "a tool result survived without its assistant turn")
        }
    }

    // MARK: - 3. Wiring guard

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BonkTests
            .deletingLastPathComponent() // repo root
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("The production agent path binds and injects the conversation history")
    func productionPathWiresTheHistory() throws {
        let executor = try source("Bonk/Services/Agent/AgentToolExecutor.swift")
        #expect(executor.contains("agentMessageHistory.bind(to: conversation?.id)"),
                "the agent path must bind the model's memory to the conversation before the run")
        #expect(executor.contains("messageHistory: agentMessageHistory"),
                "the agent path must inject the conversation history into the runtime")
    }

    @Test("The runtime reads the history it was given")
    func runtimeReadsTheInjectedHistory() throws {
        let runtime = try source("Bonk/Services/Agent/Runtime/AgentRuntime.swift")
        #expect(runtime.contains("messageHistory?.record"),
                "the runtime must record what it sends, or the history stays empty")
        #expect(runtime.contains("messageHistory?.replaceAll"),
                "the runtime must sync the history after compaction, or the next run undoes it")
    }

    @Test("The final-synthesis instruction is never written to the history")
    func synthesisInstructionNeverReachesTheHistory() throws {
        let runtime = try source("Bonk/Services/Agent/Runtime/AgentRuntime.swift")
        // The synthesis instruction is appended to the loop's messages but
        // must not be recorded. If a future edit records it, the next turn
        // reads an internal prompt as if the user had said it.
        let synthesisLine = "messages.append(.user(\"All terminal inspection commands"
        #expect(runtime.contains(synthesisLine),
                "the synthesis instruction should still be appended to the loop's messages")
        let lines = runtime.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.contains(synthesisLine) }) {
            let neighbourhood = lines[max(0, index - 6)...index].joined(separator: "\n")
            #expect(!neighbourhood.contains("messageHistory?.record"),
                    "the synthesis instruction must not be recorded in the conversation history")
        }
    }
}
