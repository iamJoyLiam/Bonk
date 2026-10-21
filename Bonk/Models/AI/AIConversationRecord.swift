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

    /// The conversation as the **model** sees it.
    ///
    /// Separate from `messages` on purpose: a bubble transcript is not a
    /// tool-calling history, and compaction rewrites the model's view
    /// without touching a single bubble.
    @Relationship(deleteRule: .cascade)
    var agentTurns: [AgentTurnRecord]

    init(title: String = "New Chat") {
        id = UUID()
        self.title = title
        createdAt = Date()
        updatedAt = Date()
        messages = []
        agentTurns = []
    }
}
