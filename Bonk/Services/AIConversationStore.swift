//
//  AIConversationStore.swift
//  Bonk
//
//  Stores AI conversation history.
//

import Foundation

/// A single AI conversation.
struct AIConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [AIMessage]
    let createdAt: Date
    var updatedAt: Date

    init(title: String = "New Chat") {
        id = UUID()
        self.title = title
        messages = []
        createdAt = Date()
        updatedAt = Date()
    }
}

/// A single message in a conversation.
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

/// Manages AI conversation history.
@Observable @MainActor
final class AIConversationStore {
    static let shared = AIConversationStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "ai_conversations"

    var conversations: [AIConversation] = []
    var currentConversation: AIConversation?

    init() {
        load()
    }

    /// Create a new conversation.
    func newConversation() -> AIConversation {
        let conversation = AIConversation()
        conversations.insert(conversation, at: 0)
        currentConversation = conversation
        save()
        return conversation
    }

    /// Add a message to the current conversation.
    func addMessage(role: AIMessage.MessageRole, content: String) {
        guard var conversation = currentConversation else {
            // Create new conversation if none exists
            var newConv = AIConversation()
            newConv.messages.append(AIMessage(role: role, content: content, timestamp: Date()))
            newConv.updatedAt = Date()
            conversations.insert(newConv, at: 0)
            currentConversation = newConv
            save()
            return
        }

        conversation.messages.append(AIMessage(role: role, content: content, timestamp: Date()))
        conversation.updatedAt = Date()

        // Update title from first user message
        if conversation.messages.count == 1, role == .user {
            conversation.title = String(content.prefix(30))
        }

        // Update in array
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
            currentConversation = conversation
        }

        save()
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
        save()
    }

    /// Clear all conversations.
    func clearAll() {
        conversations = []
        currentConversation = nil
        save()
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(conversations) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([AIConversation].self, from: data)
        else {
            return
        }
        conversations = loaded
    }
}
