import Combine
import Foundation
import os.log
import SwiftData

/// Persistent storage for AI provider configurations using SwiftData.
/// API keys remain in Keychain.
@MainActor
final class AIProviderStore: ObservableObject {
    @Published var providers: [AIProviderConfig] = []
    @Published var activeProviderID: UUID?
    /// Cached model lists keyed by provider ID. Populated by fetchModels calls.
    @Published var cachedModels: [UUID: [String]] = [:]

    private static let logger = Logger(subsystem: "com.bonk", category: "AIProviderStore")
    private var modelContext: ModelContext?

    /// Shared singleton used by both sidebar and settings.
    static let shared = AIProviderStore()

    init() {}

    func setModelContext(_ context: ModelContext) {
        modelContext = context
        load()
    }

    func load() {
        guard let context = modelContext else { return }

        do {
            let records = try context.fetch(FetchDescriptor<AIProviderRecord>(
                sortBy: [SortDescriptor(\.name)]
            ))
            providers = records.map { AIProviderConfig(from: $0) }
            activeProviderID = records.first(where: { $0.isActive })?.id
        } catch {
            Self.logger.error("Failed to load providers: \(error)")
        }
    }

    func save() {
        guard let context = modelContext else { return }

        // Update active state
        do {
            let records = try context.fetch(FetchDescriptor<AIProviderRecord>())
            for record in records {
                record.isActive = record.id == activeProviderID
            }
            try context.save()
        } catch {
            Self.logger.error("Failed to save providers: \(error)")
        }
    }

    func add(_ provider: AIProviderConfig) {
        guard let context = modelContext else { return }

        let record = provider.toRecord()
        if activeProviderID == nil {
            record.isActive = true
            activeProviderID = provider.id
        }
        context.insert(record)

        do {
            try context.save()
            load()
        } catch {
            Self.logger.error("Failed to add provider: \(error)")
        }
    }

    func update(_ provider: AIProviderConfig) {
        guard let context = modelContext else { return }

        do {
            let desc = FetchDescriptor<AIProviderRecord>(
                predicate: #Predicate { $0.id == provider.id }
            )
            if let record = try context.fetch(desc).first {
                record.name = provider.name
                record.typeRaw = provider.type.rawValue
                record.model = provider.model
                record.endpoint = provider.endpoint
                record.maxOutputTokens = provider.maxOutputTokens
                record.telemetryEnabled = provider.telemetryEnabled
                try context.save()
                load()
            }
        } catch {
            Self.logger.error("Failed to update provider: \(error)")
        }
    }

    func remove(_ id: UUID) {
        guard let context = modelContext else { return }

        do {
            let desc = FetchDescriptor<AIProviderRecord>(
                predicate: #Predicate { $0.id == id }
            )
            if let record = try context.fetch(desc).first {
                record.deleteApiKey()
                context.delete(record)
                if activeProviderID == id { activeProviderID = nil }
                try context.save()
                load()
            }
        } catch {
            Self.logger.error("Failed to remove provider: \(error)")
        }
    }

    func setActive(_ id: UUID?) {
        activeProviderID = id
        save()
    }

    // MARK: - Model Fetching

    func fetchModels(for provider: AIProviderConfig) {
        guard let url = AIProviderNetworking.modelsURL(
            endpoint: provider.endpoint, type: provider.type, apiKey: provider.apiKey
        ) else { return }
        Task {
            do {
                let request = AIProviderNetworking.makeRequest(
                    url: url, apiKey: provider.apiKey, type: provider.type
                )
                let models = try await AIProviderNetworking.fetchModels(
                    request: request, type: provider.type
                )
                await MainActor.run {
                    cachedModels[provider.id] = models
                }
            } catch {
                Self.logger.error("Failed to fetch models for \(provider.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Convenience

    var activeProvider: AIProviderConfig? {
        providers.first(where: { $0.id == activeProviderID })
    }
}

// MARK: - AIProviderConfig ↔ AIProviderRecord conversion

extension AIProviderConfig {
    init(from record: AIProviderRecord) {
        self.init(
            id: record.id,
            name: record.name,
            type: record.type,
            model: record.model,
            endpoint: record.endpoint,
            apiKey: record.apiKey,
            maxOutputTokens: record.maxOutputTokens,
            telemetryEnabled: record.telemetryEnabled
        )
    }

    func toRecord() -> AIProviderRecord {
        AIProviderRecord(
            id: id,
            name: name,
            type: type,
            model: model,
            endpoint: endpoint,
            apiKey: apiKey,
            maxOutputTokens: maxOutputTokens,
            telemetryEnabled: telemetryEnabled,
            isActive: false
        )
    }
}
