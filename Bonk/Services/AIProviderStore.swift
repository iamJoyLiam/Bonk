import Combine
import Foundation
import os.log

/// Persistent storage for AI provider configurations.
/// Uses UserDefaults for metadata, Keychain for API keys.
@MainActor
final class AIProviderStore: ObservableObject {
    @Published var providers: [AIProviderConfig] = []
    @Published var activeProviderID: UUID?

    private static let providersKey = "ai_providers"
    private static let activeKey = "ai_active_provider_id"
    private let providersKey = AIProviderStore.providersKey
    private let activeKey = AIProviderStore.activeKey

    init() {
        load()
    }

    private static let logger = Logger(subsystem: "com.bonk", category: "AIProviderStore")

    func load() {
        if let data = UserDefaults.standard.data(forKey: providersKey) {
            do {
                providers = try JSONDecoder().decode([AIProviderConfig].self, from: data)
            } catch {
                Self.logger.error("Failed to decode AI providers: \(error.localizedDescription)")
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

    // MARK: - Static Accessors (for non-ObservableObject contexts)

    /// The currently active provider, read directly from UserDefaults.
    static var activeProvider: AIProviderConfig? {
        guard let data = UserDefaults.standard.data(forKey: providersKey),
              let providers = try? JSONDecoder().decode([AIProviderConfig].self, from: data),
              let activeId = UserDefaults.standard.string(forKey: activeKey) else { return nil }
        return providers.first(where: { $0.id.uuidString == activeId })
    }

    /// All configured providers.
    static var allProviders: [AIProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: providersKey) else { return [] }
        return (try? JSONDecoder().decode([AIProviderConfig].self, from: data)) ?? []
    }

    /// Update a specific provider by ID.
    static func updateProvider(_ provider: AIProviderConfig) {
        var providers = allProviders
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx] = provider
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: providersKey)
        }
    }
}
