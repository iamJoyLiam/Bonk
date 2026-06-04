import Combine
import Foundation
import os.log

/// Persistent storage for AI provider configurations.
/// Uses UserDefaults for metadata, Keychain for API keys.
@MainActor
final class AIProviderStore: ObservableObject {
    @Published var providers: [AIProviderConfig] = []
    @Published var activeProviderID: UUID?

    private let providersKey = "ai_providers"
    private let activeKey = "ai_active_provider_id"

    init() {
        load()
    }

    private static let logger = Logger(subsystem: "com.bonk", category: "AIProviderStore")

    func load() {
        if let data = UserDefaults.standard.data(forKey: providersKey) {
            do {
                providers = try JSONDecoder().decode([AIProviderConfig].self, from: data)
            } catch {
                Self.logger.error("Failed to decode AI providers (\(data.count) bytes): \(error.localizedDescription). Data may be corrupted — providers reset to empty.")
                // Clear corrupted data to prevent repeated failures
                UserDefaults.standard.removeObject(forKey: providersKey)
            }
        }
        if let idString = UserDefaults.standard.string(forKey: activeKey) {
            activeProviderID = UUID(uuidString: idString)
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: providersKey)
        }
        if let id = activeProviderID {
            UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeKey)
        }
    }

    func add(_ provider: AIProviderConfig) {
        providers.append(provider)
        save()
    }

    func update(_ provider: AIProviderConfig) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
            save()
        }
    }

    func remove(_ id: UUID) {
        if let provider = providers.first(where: { $0.id == id }) {
            provider.deleteApiKey()
        }
        providers.removeAll { $0.id == id }
        if activeProviderID == id { activeProviderID = nil }
        save()
    }

    func setActive(_ id: UUID?) {
        activeProviderID = id
        save()
    }
}
