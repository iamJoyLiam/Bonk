import Foundation
import SwiftData

/// Persisted AI conversation.
@Model
final class AIConversationRecord {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade)
    var messages: [AIMessageRecord]

    init(title: String = "New Chat") {
        id = UUID()
        self.title = title
        createdAt = Date()
        updatedAt = Date()
        messages = []
    }
}
