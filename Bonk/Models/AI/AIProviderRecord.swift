import Foundation
import SwiftData

/// Persisted AI provider configuration.
/// API key remains in Keychain (not stored here).
@Model
final class AIProviderRecord {
    var id: UUID
    var name: String
    var typeRaw: String
    var model: String
    var endpoint: String
    var maxOutputTokens: Int?
    var telemetryEnabled: Bool
    var isActive: Bool

    var type: AIProviderType {
        get { AIProviderType(rawValue: typeRaw) ?? .claude }
        set { typeRaw = newValue.rawValue }
    }

    /// Keychain account for API key.
    var keychainAccount: String {
        "ai_provider_\(id.uuidString)"
    }

    var apiKey: String {
        get { KeychainHelper.get(for: keychainAccount) ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(for: keychainAccount)
            } else {
                KeychainHelper.set(newValue, for: keychainAccount)
            }
        }
    }

    var hasAPIKey: Bool {
        KeychainHelper.get(for: keychainAccount) != nil
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        type: AIProviderType = .claude,
        model: String = "",
        endpoint: String = "",
        apiKey: String = "",
        maxOutputTokens: Int? = nil,
        telemetryEnabled: Bool = false,
        isActive: Bool = false
    ) {
        self.id = id
        self.name = name
        typeRaw = type.rawValue
        self.model = model
        self.endpoint = endpoint.isEmpty ? type.defaultEndpoint : endpoint
        self.maxOutputTokens = maxOutputTokens
        self.telemetryEnabled = telemetryEnabled
        self.isActive = isActive

        if !apiKey.isEmpty {
            KeychainHelper.set(apiKey, for: "ai_provider_\(id.uuidString)")
        }
    }

    func deleteApiKey() {
        KeychainHelper.delete(for: keychainAccount)
    }
}
