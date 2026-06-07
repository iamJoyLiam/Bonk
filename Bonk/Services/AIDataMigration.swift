import Foundation
import os.log
import SwiftData

/// One-time migration of AI data from UserDefaults to SwiftData.
enum AIDataMigration {
    private static let migrationKey = "ai_data_migrated_to_swiftdata"
    private static let logger = Logger(subsystem: "com.bonk", category: "AIDataMigration")

    /// Run migration if needed. Call once at app launch after ModelContainer is ready.
    static func migrateIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        logger.info("Starting AI data migration from UserDefaults to SwiftData")

        let success = migrateConversations(context: context) && migrateProviders(context: context)

        if success {
            UserDefaults.standard.set(true, forKey: migrationKey)
            logger.info("AI data migration complete")
        } else {
            logger.error("AI data migration failed, will retry next launch")
        }
    }

    // MARK: - Conversations

    @discardableResult
    private static func migrateConversations(context: ModelContext) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "ai_conversations") else {
            logger.info("No conversations to migrate")
            return true // Nothing to migrate = success
        }

        guard let conversations = try? JSONDecoder().decode([LegacyAIConversation].self, from: data) else {
            logger.error("Failed to decode legacy conversations")
            return false
        }

        for legacy in conversations {
            let record = AIConversationRecord(title: legacy.title)
            record.id = legacy.id
            record.createdAt = legacy.createdAt
            record.updatedAt = legacy.updatedAt

            for legacyMsg in legacy.messages {
                let msg = AIMessageRecord(
                    role: legacyMsg.role == "assistant" ? .assistant : .user,
                    content: legacyMsg.content,
                    timestamp: legacyMsg.timestamp
                )
                msg.id = legacyMsg.id
                msg.conversation = record
                record.messages.append(msg)
            }

            context.insert(record)
        }

        do {
            try context.save()
            UserDefaults.standard.removeObject(forKey: "ai_conversations")
            logger.info("Migrated \(conversations.count) conversations")
            return true
        } catch {
            logger.error("Failed to save migrated conversations: \(error)")
            return false
        }
    }

    // MARK: - HostItem Relationships

    /// Migrate string-based group/credentialID to proper @Relationship.
    /// Safe to run multiple times — skips already-migrated items.
    static func migrateHostRelationships(context: ModelContext) {
        let key = "host_relationships_migrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        do {
            let hosts = try context.fetch(FetchDescriptor<HostItem>())
            var migrated = 0

            for host in hosts {
                if host.groupRef == nil, let groupName = host.group, !groupName.isEmpty {
                    let desc = FetchDescriptor<HostGroup>(
                        predicate: #Predicate { $0.name == groupName }
                    )
                    host.groupRef = try? context.fetch(desc).first
                    if host.groupRef != nil { migrated += 1 }
                }

                if host.credentialRef == nil, let credName = host.credentialID, !credName.isEmpty {
                    let desc = FetchDescriptor<Credential>(
                        predicate: #Predicate { $0.name == credName }
                    )
                    host.credentialRef = try? context.fetch(desc).first
                    if host.credentialRef != nil { migrated += 1 }
                }
            }

            try context.save()
            UserDefaults.standard.set(true, forKey: key)
            logger.info("Host relationship migration complete: \(migrated) relationships created")
        } catch {
            logger.error("Host relationship migration failed: \(error)")
        }
    }

    // MARK: - Providers

    @discardableResult
    private static func migrateProviders(context: ModelContext) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "ai_providers") else {
            logger.info("No providers to migrate")
            return true
        }

        guard let providers = try? JSONDecoder().decode([LegacyAIProvider].self, from: data) else {
            logger.error("Failed to decode legacy providers")
            return false
        }

        let activeIDString = UserDefaults.standard.string(forKey: "ai_active_provider_id")
        let activeID = activeIDString.flatMap(UUID.init(uuidString:))

        for legacy in providers {
            let record = AIProviderRecord(
                id: legacy.id,
                name: legacy.name,
                type: AIProviderType(rawValue: legacy.type) ?? .custom,
                model: legacy.model,
                endpoint: legacy.endpoint,
                maxOutputTokens: legacy.maxOutputTokens,
                telemetryEnabled: legacy.telemetryEnabled,
                isActive: legacy.id == activeID
            )
            context.insert(record)
        }

        do {
            try context.save()
            UserDefaults.standard.removeObject(forKey: "ai_providers")
            UserDefaults.standard.removeObject(forKey: "ai_active_provider_id")
            logger.info("Migrated \(providers.count) providers")
            return true
        } catch {
            logger.error("Failed to save migrated providers: \(error)")
            return false
        }
    }
}

// MARK: - Legacy Codable Types

private struct LegacyAIConversation: Codable {
    let id: UUID
    let title: String
    let messages: [LegacyAIMessage]
    let createdAt: Date
    let updatedAt: Date
}

private struct LegacyAIMessage: Codable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date
}

private struct LegacyAIProvider: Codable {
    let id: UUID
    let name: String
    let type: String
    let model: String
    let endpoint: String
    let maxOutputTokens: Int?
    let telemetryEnabled: Bool
}
