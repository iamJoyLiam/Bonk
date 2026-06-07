import Foundation
import SwiftData

/// A single message in an AI conversation.
@Model
final class AIMessageRecord {
    var id: UUID
    var roleRaw: String // "user" or "assistant"
    var content: String
    var timestamp: Date

    var conversation: AIConversationRecord?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    enum MessageRole: String, Codable {
        case user
        case assistant
    }

    init(role: MessageRole, content: String, timestamp: Date = Date()) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        self.timestamp = timestamp
    }
}
