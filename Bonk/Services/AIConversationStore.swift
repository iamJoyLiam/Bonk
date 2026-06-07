import Foundation
import os.log
import SwiftData

/// Manages AI conversation history using SwiftData.
@Observable @MainActor
final class AIConversationStore {
    static let shared = AIConversationStore()
    private static let logger = Logger(subsystem: "com.bonk", category: "AIConversationStore")

    private var modelContext: ModelContext?

    var conversations: [AIConversation] = []
    var currentConversation: AIConversation?

    func setModelContext(_ context: ModelContext) {
        modelContext = context
        load()
    }

    /// Create a new conversation.
    func newConversation() -> AIConversation {
        let conversation = AIConversation()
        conversations.insert(conversation, at: 0)
        currentConversation = conversation

        if let context = modelContext {
            let record = AIConversationRecord(title: conversation.title)
            record.id = conversation.id
            context.insert(record)
            save(context, operation: "newConversation")
        }

        return conversation
    }

    /// Add a message to the current conversation.
    func addMessage(role: AIMessage.MessageRole, content: String) {
        guard var conversation = currentConversation else {
            var newConv = AIConversation()
            newConv.messages.append(AIMessage(role: role, content: content, timestamp: Date()))
            newConv.updatedAt = Date()
            conversations.insert(newConv, at: 0)
            currentConversation = newConv

            if let context = modelContext {
                let record = AIConversationRecord(title: newConv.title)
                record.id = newConv.id
                let msg = AIMessageRecord(role: role == .assistant ? .assistant : .user, content: content)
                msg.conversation = record
                record.messages.append(msg)
                context.insert(record)
                save(context, operation: "addMessage-new")
            }
            return
        }

        conversation.messages.append(AIMessage(role: role, content: content, timestamp: Date()))
        conversation.updatedAt = Date()

        if conversation.messages.count == 1, role == .user {
            conversation.title = String(content.prefix(30))
        }

        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
            currentConversation = conversation
        }

        if let context = modelContext {
            let desc = FetchDescriptor<AIConversationRecord>(
                predicate: #Predicate { $0.id == conversation.id }
            )
            if let record = try? context.fetch(desc).first {
                let msg = AIMessageRecord(role: role == .assistant ? .assistant : .user, content: content)
                msg.conversation = record
                record.messages.append(msg)
                record.updatedAt = Date()
                if conversation.messages.count == 1, role == .user {
                    record.title = String(content.prefix(30))
                }
                save(context, operation: "addMessage-append")
            }
        }
    }

    /// Select a conversation.
    func selectConversation(_ id: UUID) {
        currentConversation = conversations.first(where: { $0.id == id })
    }

    /// Delete a conversation.
    func deleteConversation(_ id: UUID) {
        conversations.removeAll(where: { $0.id == id })
        if currentConversation?.id == id {
            currentConversation = conversations.first
        }

        if let context = modelContext {
            let desc = FetchDescriptor<AIConversationRecord>(
                predicate: #Predicate { $0.id == id }
            )
            if let record = try? context.fetch(desc).first {
                context.delete(record)
                save(context, operation: "deleteConversation")
            }
        }
    }

    /// Clear all conversations.
    func clearAll() {
        conversations = []
        currentConversation = nil

        if let context = modelContext {
            do {
                try context.delete(model: AIConversationRecord.self)
                try context.save()
            } catch {
                Self.logger.error("clearAll failed: \(error)")
            }
        }
    }

    // MARK: - Persistence

    private func save(_ context: ModelContext, operation: String) {
        do {
            try context.save()
        } catch {
            Self.logger.error("Save failed (\(operation)): \(error)")
        }
    }

    private func load() {
        guard let context = modelContext else { return }

        let desc = FetchDescriptor<AIConversationRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let records: [AIConversationRecord]
        do {
            records = try context.fetch(desc)
        } catch {
            Self.logger.error("load fetch failed: \(error)")
            return
        }

        conversations = records.map { record in
            var conv = AIConversation(title: record.title)
            conv.id = record.id
            conv.createdAt = record.createdAt
            conv.updatedAt = record.updatedAt
            conv.messages = record.messages
                .sorted(by: { $0.timestamp < $1.timestamp })
                .map { msg in
                    AIMessage(
                        role: msg.role == .assistant ? .assistant : .user,
                        content: msg.content,
                        timestamp: msg.timestamp
                    )
                }
            return conv
        }
    }
}

// MARK: - Shared Types

struct AIConversation: Identifiable, Codable {
    var id: UUID
    var title: String
    var messages: [AIMessage]
    var createdAt: Date
    var updatedAt: Date

    init(title: String = "New Chat") {
        id = UUID()
        self.title = title
        messages = []
        createdAt = Date()
        updatedAt = Date()
    }
}

struct AIMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    enum MessageRole: String, Codable {
        case user
        case assistant
    }

    init(role: MessageRole, content: String, timestamp: Date = Date()) {
        id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
