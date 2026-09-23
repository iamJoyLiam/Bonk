import SwiftData
import Testing
@testable import Bonk

/// "+" must not persist anything by itself: the conversation is created on
/// first submit, and abandoned empty drafts are pruned instead of piling up.
@Suite("AI Conversation Lazy Creation Tests")
struct AIConversationLazyCreationTests {
    @MainActor
    private func makeContext() throws -> ModelContext {
        let schema = Schema([AIConversationRecord.self, AIMessageRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    @MainActor
    private func allConversations(in context: ModelContext) throws -> [AIConversationRecord] {
        try context.fetch(FetchDescriptor<AIConversationRecord>())
    }

    @Test("ensure returns existing without inserting")
    @MainActor
    func ensureKeepsExisting() throws {
        let context = try makeContext()
        let store = AIConversationStore()
        let first = store.ensureConversation(nil, context: context)
        let second = store.ensureConversation(first, context: context)
        #expect(second.id == first.id)
        #expect(try allConversations(in: context).count == 1)
        #expect(store.lastConversationID == first.id)
    }

    @Test("prune removes only message-less drafts")
    @MainActor
    func pruneKeepsUsedConversations() throws {
        let context = try makeContext()
        let store = AIConversationStore()
        let draft = store.ensureConversation(nil, context: context)
        let used = store.ensureConversation(nil, context: context)
        store.addMessage(to: used, role: .user, content: "hello", context: context)
        #expect(try allConversations(in: context).count == 2)

        store.pruneEmptyConversations(try allConversations(in: context), context: context)
        let remaining = try allConversations(in: context)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == used.id)
        #expect(draft.messages.isEmpty)
    }

    @Test("repeated plus without submit leaves nothing behind")
    @MainActor
    func plusWithoutSubmitPersistsNothing() throws {
        let context = try makeContext()
        let store = AIConversationStore()
        // Simulate three "+" presses: prune, reset to nil, never ensure.
        for _ in 0..<3 {
            store.pruneEmptyConversations(try allConversations(in: context), context: context)
        }
        #expect(try allConversations(in: context).isEmpty)
        // First submit persists exactly one conversation.
        let conv = store.ensureConversation(nil, context: context)
        store.addMessage(to: conv, role: .user, content: "first message", context: context)
        #expect(try allConversations(in: context).count == 1)
    }
}
