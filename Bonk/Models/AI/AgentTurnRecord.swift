//
//  AgentTurnRecord.swift
//  Bonk
//
//  One turn of the conversation **as the model sees it**.
//
//  The display transcript (`AIMessageRecord`) is not this. A display
//  transcript is a list of bubbles; the model's view is a
//  tool-calling history, and the two are not the same thing:
//
//  - the model needs the assistant turn *with its tool calls* (the ids,
//    the names, the arguments) and every tool result *with the id of the
//    call it answers*;
//  - a provider rejects a history whose results do not match their
//    calls, so a transcript without those ids is not a legal history —
//    it cannot be sent back to a model at all.
//
//  So the two are stored apart: `AIMessageRecord` is what the user
//  reads, `AgentTurnRecord` is what the model can be resumed with.
//  Keeping them apart also means compaction can rewrite the model's
//  view without touching a single bubble.
//
//  The role is the API's role, not the app's: `user`, `assistant`,
//  `tool`. A `tool` row is a tool result and carries `toolCallID`; an
//  `assistant` row may carry `toolCallsJSON` — the calls it asked for.
//

import Foundation
import SwiftData

/// One turn of the model-facing history.
@Model
final class AgentTurnRecord {
    var id: UUID
    /// The API role: `user`, `assistant` or `tool`.
    var roleRaw: String
    /// The message body, exactly as the model saw it.
    var content: String
    /// The call this result answers. Set on `tool` rows.
    var toolCallID: String?
    /// The tool calls the assistant asked for, as JSON.
    ///
    /// The id, the name and the arguments — the three things a provider
    /// needs to match a result to its call.
    var toolCallsJSON: String?
    var timestamp: Date

    @Relationship(inverse: \AIConversationRecord.agentTurns)
    var conversation: AIConversationRecord?

    enum Role: String, Codable {
        case user
        case assistant
        case tool
    }

    var role: Role {
        get { Role(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(
        role: Role,
        content: String,
        toolCallID: String? = nil,
        toolCallsJSON: String? = nil,
        timestamp: Date = Date()
    ) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        self.toolCallID = toolCallID
        self.toolCallsJSON = toolCallsJSON
        self.timestamp = timestamp
    }
}
