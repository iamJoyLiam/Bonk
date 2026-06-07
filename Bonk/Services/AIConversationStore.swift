import Foundation
import os.log
import SwiftData

/// Write-only service for AI conversations.
/// Reads are handled by @Query in views directly.
@Observable @MainActor
final class AIConversationStore {
    static let shared = AIConversationStore()
    private static let logger = Logger(subsystem: "com.bonk", category: "AIConversationStore")

    /// Create a new conversation and return it.
    func createConversation(title: String = "New Chat", context: ModelContext) -> AIConversationRecord {
        let record = AIConversationRecord(title: title)
        context.insert(record)
        save(context, operation: "createConversation")
        return record
    }

    /// Add a message to a conversation.
    func addMessage(
        to conversation: AIConversationRecord,
        role: AIMessageRecord.MessageRole,
        content: String,
        context: ModelContext
    ) {
        let msg = AIMessageRecord(role: role, content: content)
        msg.conversation = conversation
        conversation.messages.append(msg)
        conversation.updatedAt = Date()

        if conversation.messages.count == 1, role == .user {
            conversation.title = String(content.prefix(30))
        }

        save(context, operation: "addMessage")
    }

    /// Delete a conversation.
    func delete(_ conversation: AIConversationRecord, context: ModelContext) {
        context.delete(conversation)
        save(context, operation: "delete")
    }

    /// Delete all conversations.
    func deleteAll(context: ModelContext) {
        do {
            try context.delete(model: AIConversationRecord.self)
            try context.save()
        } catch {
            Self.logger.error("deleteAll failed: \(error)")
        }
    }

    // MARK: - Private

    private func save(_ context: ModelContext, operation: String) {
        do {
            try context.save()
        } catch {
            Self.logger.error("Save failed (\(operation)): \(error)")
        }
    }
}
