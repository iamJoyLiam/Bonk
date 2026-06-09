import Foundation
import SwiftData

/// A single message in an AI conversation.
@Model
final class AIMessageRecord {
    var id: UUID
    var roleRaw: String // "user", "assistant", "system", "commandOutput"
    var content: String
    var timestamp: Date

    // Agent-specific fields (optional, additive only)
    var agentThinking: String?
    var agentCommand: String?

    var conversation: AIConversationRecord?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    enum MessageRole: String, Codable {
        case user
        case assistant
        case system
        case commandOutput
    }

    init(
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        thinking: String? = nil,
        command: String? = nil
    ) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        self.timestamp = timestamp
        agentThinking = thinking
        agentCommand = command
    }
}
