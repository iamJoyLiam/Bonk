//
//  AgentSessionPersistenceTests.swift
//  BonkTests
//
//  The conversation that survives a restart.
//
//  The display transcript is not a tool-calling history. A provider
//  rejects a history whose tool results do not match their calls, so a
//  list of bubbles cannot be sent back to a model at all — which means
//  an agent that restarts has to start from nothing, however much the
//  transcript shows.
//
//  What has to hold:
//
//  1. **The turns come back.** After a restart the next run reads the
//     conversation's prior turns, not a bare `[system, user]`.
//
//  2. **They come back legal.** The assistant turn keeps its tool calls,
//     and every tool result keeps the id of the call it answers — so the
//     history a provider sees is one it will accept.
//
//  3. **Compaction rewrites the model's view, not the transcript.** The
//     bubbles the user reads are not touched.
//

import Foundation
import SwiftData
import Testing
@testable import Bonk

@Suite("Agent session persistence")
struct AgentSessionPersistenceTests {

    // MARK: - The store

    /// A throwaway store with one conversation in it.
    private func makeStore() throws -> (ModelContainer, ModelContext, AIConversationRecord) {
        let container = try BonkStore.makeInMemory()
        let context = ModelContext(container)
        let conversation = AIConversationRecord(title: "Test")
        context.insert(conversation)
        try context.save()
        return (container, context, conversation)
    }

    /// A history over a conversation, as the app builds it.
    private func makeHistory(
        context: ModelContext,
        conversation: AIConversationRecord
    ) -> PersistentAgentMessageHistory {
        PersistentAgentMessageHistory(context: context, conversation: conversation)
    }

    /// A turn with a tool call in it.
    private func assistantToolTurn(
        id: String = "call-1",
        command: String = "df -h"
    ) -> LLMMessage {
        LLMMessage(
            role: .assistant,
            content: "",
            toolCalls: [LLMToolCall(id: id, name: "run_command", argumentsJSON: #"{"command":"\#(command)"}"#)]
        )
    }

    // MARK: - The tool calls

    @Test("The tool calls survive a round trip through the store")
    func theToolCallsRoundTrip() {
        let calls = [
            LLMToolCall(id: "call-1", name: "run_command", argumentsJSON: #"{"command":"df -h"}"#),
            LLMToolCall(id: "call-2", name: "read_file", argumentsJSON: #"{"path":"/etc/hosts"}"#)
        ]
        let json = PersistentAgentMessageHistory.encodeToolCalls(calls)
        let decoded = PersistentAgentMessageHistory.decodeToolCalls(json)
        #expect(decoded == calls, "the ids, the names and the arguments must survive")
    }

    @Test("A turn without tool calls stores none")
    func noToolCallsNoJSON() {
        #expect(PersistentAgentMessageHistory.encodeToolCalls(nil) == nil)
        #expect(PersistentAgentMessageHistory.encodeToolCalls([]) == nil)
        #expect(PersistentAgentMessageHistory.decodeToolCalls(nil) == nil)
        #expect(PersistentAgentMessageHistory.decodeToolCalls("not json") == nil)
    }

    // MARK: - The round trip

    @Test("A conversation comes back after a restart")
    func aConversationComesBack() async throws {
        let (container, context, conversation) = try makeStore()
        let history = makeHistory(context: context, conversation: conversation)

        await history.record(LLMMessage(role: .user, content: "check the disk"))
        await history.record(assistantToolTurn())
        await history.record(LLMMessage(role: .tool, content: "Filesystem  50% used", toolCallID: "call-1"))
        await history.record(LLMMessage(role: .assistant, content: "The disk is half full."))

        // The restart: a fresh context over the same store, and the
        // conversation fetched again — nothing carried over in memory.
        let freshContext = ModelContext(container)
        let fetched = try freshContext.fetch(FetchDescriptor<AIConversationRecord>()).first
        let conversationAfterRestart = try #require(fetched)
        let restarted = makeHistory(context: freshContext, conversation: conversationAfterRestart)

        let loaded = await restarted.load()
        #expect(loaded.count == 4, "every turn must come back")
        #expect(loaded.first?.role == .user)
        #expect(loaded.first?.content == "check the disk")
        #expect(loaded.last?.content == "The disk is half full.")
        // The assistant turn keeps the call it asked for — without it the
        // result that follows has nothing to belong to.
        let assistant = loaded.first { $0.role == .assistant && $0.toolCalls != nil }
        #expect(assistant != nil, "the assistant turn must keep its tool calls")
        #expect(assistant?.toolCalls?.first?.id == "call-1")
        #expect(assistant?.toolCalls?.first?.name == "run_command")
        #expect(assistant?.toolCalls?.first?.argumentsJSON.contains("df -h") == true)
    }

    @Test("The tool result keeps the id of the call it answers")
    func theToolResultKeepsItsCallID() async throws {
        let (_, context, conversation) = try makeStore()
        let history = makeHistory(context: context, conversation: conversation)
        await history.record(assistantToolTurn())
        await history.record(LLMMessage(role: .tool, content: "Filesystem  50% used", toolCallID: "call-1"))

        let loaded = await history.load()
        let tool = loaded.first { $0.role == .tool }
        #expect(tool != nil, "the tool result must come back")
        #expect(tool?.toolCallID == "call-1", "without the id the result cannot be matched to its call")
    }

    @Test("The history that comes back is one a provider will accept")
    func theLoadedHistoryIsLegal() async throws {
        let (_, context, conversation) = try makeStore()
        let history = makeHistory(context: context, conversation: conversation)
        await history.record(LLMMessage(role: .user, content: "check the disk"))
        await history.record(assistantToolTurn())
        await history.record(LLMMessage(role: .tool, content: "Filesystem  50% used", toolCallID: "call-1"))
        await history.record(LLMMessage(role: .assistant, content: "The disk is half full."))

        let loaded = await history.load()
        // The projection is the rule a provider applies: a result whose
        // call is missing is dropped, and the turn that asked for it goes
        // with it. A history that survives the projection is one the
        // provider will accept.
        #expect(loaded.count == 4, "every turn must survive the projection")
        #expect(loaded.filter { $0.role == .tool }.count == 1)
    }

    @Test("A history whose result lost its call is not legal")
    func aHistoryWithoutTheCallIDIsNotLegal() {
        // The rule the persistence has to keep: a result with no call is
        // dropped, and the assistant turn that asked for it goes with it.
        let messages = [
            LLMMessage(role: .user, content: "check the disk"),
            assistantToolTurn(),
            LLMMessage(role: .tool, content: "Filesystem  50% used", toolCallID: "call-1")
        ]
        #expect(AgentHistoryProjection.validPrefix(messages).count == 3)

        let withoutID = [
            messages[0],
            messages[1],
            LLMMessage(role: .tool, content: "Filesystem  50% used", toolCallID: nil)
        ]
        #expect(
            AgentHistoryProjection.validPrefix(withoutID).count < 3,
            "a result without its call must not survive — this is what the persistence prevents"
        )
    }

    // MARK: - Compaction

    @Test("Compaction rewrites the model's view and leaves the transcript alone")
    func compactionRewritesTheModelView() async throws {
        let (_, context, conversation) = try makeStore()
        let history = makeHistory(context: context, conversation: conversation)
        await history.record(LLMMessage(role: .user, content: "check the disk"))
        await history.record(assistantToolTurn())
        await history.record(LLMMessage(role: .tool, content: "Filesystem  50% used", toolCallID: "call-1"))

        // Compaction keeps the request and the answer, drops the middle.
        await history.replaceAll([
            LLMMessage(role: .user, content: "check the disk"),
            LLMMessage(role: .assistant, content: "The disk is half full.")
        ])

        let loaded = await history.load()
        #expect(loaded.count == 2, "the compacted view replaces the old one")
        #expect(loaded.first?.content == "check the disk")
        #expect(loaded.last?.content == "The disk is half full.")
        #expect(
            conversation.messages.isEmpty,
            "the transcript the user reads is a different thing and must not be touched"
        )
    }

    @Test("The system prompt is never stored")
    func theSystemPromptIsNotStored() async throws {
        let (_, context, conversation) = try makeStore()
        let history = makeHistory(context: context, conversation: conversation)
        await history.record(LLMMessage(role: .system, content: "You are Bonk's assistant."))
        await history.record(LLMMessage(role: .user, content: "hello"))
        let loaded = await history.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.role == .user)
    }
}
