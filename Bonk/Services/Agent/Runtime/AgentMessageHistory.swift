//
//  AgentMessageHistory.swift
//  Bonk
//
//  Conversation-scoped, model-facing message history.
//
//  The agent loop used to rebuild `[system, user]` on every run, so the model
//  could not see what it had already said, run, or concluded: turn two was
//  indistinguishable from turn one.
//
//  The persisted SwiftData conversation cannot stand in for this. It is a
//  display transcript: `AgentEngine.appendAgentMessage` maps command output
//  onto the `system` role (AgentEngine.swift:396-400) and the records carry
//  no tool-call ids, so the result is not a legal tool-calling history.
//
//  This type is the seam that lets a run start from the conversation's prior
//  turns, and nothing more.
//

import Foundation
import os

/// Model-facing history for one conversation.
///
/// The contract is deliberately narrow: non-system messages only, oldest
/// first. Implementations ignore system messages handed to `record` — the
/// system prompt is rebuilt on every run from the environment context and
/// the project instructions, and a stored copy would pin a stale host name
/// into today's prompt.
protocol AgentMessageHistory: AnyObject, Sendable {
    /// Prior turns, oldest first. Never contains a system message.
    func load() -> [LLMMessage]
    /// Append one turn. System messages are ignored.
    func record(_ message: LLMMessage)
    /// Replace the whole history — used after compaction, so the next run
    /// does not resurrect the context that compaction just removed.
    func replaceAll(_ messages: [LLMMessage])
}

/// In-memory history, keyed by conversation.
///
/// Histories are kept per conversation rather than as one running list, so
/// switching chats in the sidebar and coming back does not lose the
/// conversation's memory, and two conversations can never see each other's
/// turns.
final class ConversationMessageHistory: AgentMessageHistory, @unchecked Sendable {
    /// Character budget for the stored history. The runtime compacts a single
    /// run's messages at 60k input tokens; a history that survives across runs
    /// has to be bounded too, or the prompt grows with every turn until the
    /// budget controller stops the run outright.
    static let defaultMaxCharacters = 120_000

    private struct State {
        var currentID: UUID?
        var byConversation: [UUID: [LLMMessage]] = [:]
        var maxCharacters: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(maxCharacters: Int = ConversationMessageHistory.defaultMaxCharacters) {
        state = OSAllocatedUnfairLock(uncheckedState: State(
            currentID: nil,
            byConversation: [:],
            maxCharacters: maxCharacters
        ))
    }

    /// Point the history at a conversation. Switching conversations switches
    /// which stored turns are visible; it does not erase them.
    ///
    /// A nil conversation means "no conversation to key on". Rather than
    /// inheriting an unrelated run's turns, the history then reads as empty
    /// and records nothing, so an unkeyed run can never borrow another run's
    /// context.
    func bind(to conversationID: UUID?) {
        state.withLock { $0.currentID = conversationID }
    }

    /// Drop everything remembered about the current conversation.
    ///
    /// Used by "new chat": the transcript the user reads and the memory the
    /// model holds are two different things, and both have to go for the
    /// gesture to mean what it says.
    func reset() {
        state.withLock { state in
            guard let id = state.currentID else { return }
            state.byConversation[id] = []
        }
    }

    func load() -> [LLMMessage] {
        state.withLock { state in
            guard let id = state.currentID else { return [] }
            let stored = state.byConversation[id] ?? []
            return AgentHistoryProjection.boundedPrefix(
                stored, maxCharacters: state.maxCharacters
            )
        }
    }

    func record(_ message: LLMMessage) {
        guard message.role != .system else { return }
        state.withLock { state in
            guard let id = state.currentID else { return }
            var stored = state.byConversation[id] ?? []
            stored.append(message)
            // Bound the stored history too, not just what load() returns:
            // an unbounded store would grow for the life of the session.
            //
            // Deliberately NOT projected here. A turn is written in pieces —
            // the assistant asks for a tool call, the result arrives after —
            // and projecting mid-write would read the half-written turn as
            // "unanswered" and throw it away.
            state.byConversation[id] = AgentHistoryProjection.trimToBudget(
                stored, maxCharacters: state.maxCharacters
            )
        }
    }

    func replaceAll(_ messages: [LLMMessage]) {
        state.withLock { state in
            guard let id = state.currentID else { return }
            // Not projected: the caller owns this sequence (compaction built
            // it deliberately), and load() projects whatever comes back.
            state.byConversation[id] = AgentHistoryProjection.trimToBudget(
                messages.filter { $0.role != .system },
                maxCharacters: state.maxCharacters
            )
        }
    }
}

/// Pure projection of a stored history into something a provider accepts.
///
/// Kept free of state so both rules can be exercised directly, without a
/// runtime, a provider, or a network.
enum AgentHistoryProjection {

    /// Trim a history to the longest prefix a provider will accept.
    ///
    /// Two rules, both forced by the wire format rather than by taste:
    ///
    /// 1. A tool result must directly follow the assistant turn that asked
    ///    for it. A result with no matching call, or one that arrives after
    ///    an unrelated turn, is rejected.
    /// 2. Every tool call in an assistant turn must be answered. A run that
    ///    ended on a budget halt, a cancellation, or a crash leaves the
    ///    assistant turn unanswered, and providers reject that with a 400 —
    ///    which would turn "the agent stopped" into "the whole conversation
    ///    is broken".
    ///
    /// Rule 2 is enforced by dropping the offending assistant turn *and
    /// everything after it*: the tool results belonging to that turn have to
    /// go with it, because a provider that sees a result without its call
    /// rejects the sequence too.
    static func validPrefix(_ messages: [LLMMessage]) -> [LLMMessage] {
        var result: [LLMMessage] = []
        // Calls requested by the assistant turn currently open, not yet
        // answered by a tool result.
        var awaiting: Set<String> = []
        // Index in `result` of the assistant turn whose calls are open.
        var openTurn: Int?

        func closeOpenTurn() {
            if let index = openTurn {
                result.removeSubrange(index...)
            }
            awaiting.removeAll()
            openTurn = nil
        }

        for message in messages {
            switch message.role {
            case .system:
                // The system prompt is rebuilt per run; it never belongs here.
                continue
            case .user:
                // A user turn ends any open assistant turn.
                closeOpenTurn()
                result.append(message)
            case .assistant:
                closeOpenTurn()
                result.append(message)
                if let calls = message.toolCalls, !calls.isEmpty {
                    awaiting = Set(calls.map(\.id))
                    openTurn = result.count - 1
                }
            case .tool:
                guard let callID = message.toolCallID, awaiting.contains(callID) else {
                    // Orphaned or out-of-order result: no open call matches.
                    continue
                }
                awaiting.remove(callID)
                result.append(message)
                if awaiting.isEmpty { openTurn = nil }
            }
        }

        // End of history: an assistant turn with unanswered calls is invalid.
        closeOpenTurn()
        return result
    }

    /// Trim a history to fit a character budget, keeping the most recent
    /// turns.
    ///
    /// The suffix is contiguous: dropping an older turn in the middle of a
    /// sequence would leave an orphaned tool result behind, so the cut is
    /// made at a turn boundary and the projection cleans up after it.
    ///
    /// This is the write-side trim. It deliberately does not project: a turn
    /// is written in pieces, and the assistant half of a tool call is written
    /// before its result exists.
    static func trimToBudget(_ messages: [LLMMessage], maxCharacters: Int) -> [LLMMessage] {
        guard maxCharacters > 0 else { return [] }
        guard totalCost(messages) > maxCharacters else { return messages }

        var kept: [LLMMessage] = []
        var used = 0
        for message in messages.reversed() {
            let cost = cost(of: message)
            if used + cost > maxCharacters { break }
            used += cost
            kept.append(message)
        }
        kept.reverse()
        return kept
    }

    /// The read path: trim to budget, then project to a sequence a provider
    /// accepts.
    static func boundedPrefix(_ messages: [LLMMessage], maxCharacters: Int) -> [LLMMessage] {
        validPrefix(trimToBudget(messages, maxCharacters: maxCharacters))
    }

    /// Rough size of one message in characters. Tool call arguments count
    /// toward the prompt, so they count here too.
    private static func cost(of message: LLMMessage) -> Int {
        let overhead = 64
        let calls = message.toolCalls?.reduce(0) { $0 + $1.argumentsJSON.count } ?? 0
        return message.content.count + calls + overhead
    }

    private static func totalCost(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + cost(of: $1) }
    }
}
