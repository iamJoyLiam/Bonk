//
//  PersistentAgentMessageHistory.swift
//  Bonk
//
//  History that survives a restart.
//
//  The in-memory history remembers a conversation for as long as the app
//  runs. This one remembers it in the store, so the next run — after a
//  restart, after a crash, on another day — can start from where the
//  last one stopped.
//
//  What it stores is the **model's** view of the conversation, not the
//  transcript the user reads: the assistant turn with its tool calls,
//  and every tool result with the id of the call it answers. A provider
//  rejects a history whose results do not match their calls, so a
//  transcript of bubbles cannot be sent back to a model at all.
//
//  The records live in their own table (`AgentTurnRecord`), beside the
//  display transcript and not inside it, so compaction can rewrite the
//  model's view without touching a single bubble.
//
//  Every write goes through the main actor: SwiftData's context is
//  thread-confined, and the app's context is the app's one.
//

import Foundation
import os
import SwiftData

/// Conversation history backed by the store.
final class PersistentAgentMessageHistory: AgentMessageHistory, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.bonk", category: "AgentHistory")

    private let context: ModelContext
    private let conversation: AIConversationRecord

    init(context: ModelContext, conversation: AIConversationRecord) {
        self.context = context
        self.conversation = conversation
    }

    /// The conversation's prior turns, oldest first.
    ///
    /// Projected through the same rules the in-memory history uses: a
    /// result whose call is missing is dropped rather than sent to a
    /// provider that would reject the whole sequence.
    func load() async -> [LLMMessage] {
        let messages = await MainActor.run { self.readRecords() }
        return AgentHistoryProjection.validPrefix(messages)
    }

    /// Append one turn.
    func record(_ message: LLMMessage) async {
        await MainActor.run { self.write(message) }
    }

    /// Replace the whole history — after compaction.
    func replaceAll(_ messages: [LLMMessage]) async {
        await MainActor.run { self.rewrite(messages) }
    }

    // MARK: - The store

    private func readRecords() -> [LLMMessage] {
        let records = conversation.agentTurns.sorted { $0.timestamp < $1.timestamp }
        return records.compactMap { record in
            LLMMessage(
                role: Self.role(for: record.role),
                content: record.content,
                toolCallID: record.toolCallID,
                toolCalls: Self.decodeToolCalls(record.toolCallsJSON)
            )
        }
    }

    private func write(_ message: LLMMessage) {
        // The system prompt is rebuilt on every run from the environment
        // and the project's instructions; a stored copy would pin a stale
        // host name into today's prompt.
        guard message.role != .system else { return }
        let record = AgentTurnRecord(
            role: Self.role(for: message.role),
            content: message.content,
            toolCallID: message.toolCallID,
            toolCallsJSON: Self.encodeToolCalls(message.toolCalls)
        )
        record.conversation = conversation
        conversation.agentTurns.append(record)
        save()
    }

    /// Rewrite the conversation's turns.
    ///
    /// Compaction removed context the model must not see again, so the
    /// stored view is replaced rather than appended to. The display
    /// transcript is a different table and is not touched.
    private func rewrite(_ messages: [LLMMessage]) {
        conversation.agentTurns.removeAll()
        for message in messages where message.role != .system {
            write(message)
        }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Self.logger.error("Saving the agent history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - The shapes

    private static func role(for role: LLMMessage.Role) -> AgentTurnRecord.Role {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        case .system: return .user
        }
    }

    private static func role(for role: AgentTurnRecord.Role) -> LLMMessage.Role {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        }
    }

    /// The tool calls, as JSON.
    ///
    /// The arguments are kept exactly as the model sent them — a string
    /// of JSON — so a round trip through the store does not "fix" or
    /// alter what the provider will parse.
    static func encodeToolCalls(_ calls: [LLMToolCall]?) -> String? {
        guard let calls, !calls.isEmpty else { return nil }
        let payload: [[String: String]] = calls.map {
            ["id": $0.id, "name": $0.name, "arguments": $0.argumentsJSON]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    /// The tool calls, from JSON.
    static func decodeToolCalls(_ json: String?) -> [LLMToolCall]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return nil
        }
        let calls = payload.compactMap { entry -> LLMToolCall? in
            guard let id = entry["id"], let name = entry["name"] else { return nil }
            return LLMToolCall(id: id, name: name, argumentsJSON: entry["arguments"] ?? "{}")
        }
        return calls.isEmpty ? nil : calls
    }
}
