import Foundation

/// Configuration for an AI provider instance.
/// API key is stored in Keychain, not in UserDefaults.
struct AIProviderConfig: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var type: AIProviderType
    var model: String
    var endpoint: String
    var maxOutputTokens: Int?
    var telemetryEnabled: Bool

    /// Exclude apiKey from Codable — stored in Keychain
    enum CodingKeys: String, CodingKey {
        case id, name, type, model, endpoint, maxOutputTokens, telemetryEnabled
    }

    var displayName: String {
        if !name.isEmpty { return name }
        return type.displayName
    }

    // MARK: - Keychain-backed API key

    private var keychainAccount: String {
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
        telemetryEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.model = model
        self.endpoint = endpoint.isEmpty ? type.defaultEndpoint : endpoint
        self.maxOutputTokens = maxOutputTokens
        self.telemetryEnabled = telemetryEnabled

        // Store API key in Keychain after id is set
        if !apiKey.isEmpty {
            KeychainHelper.set(apiKey, for: "ai_provider_\(id.uuidString)")
        }
    }

    func deleteApiKey() {
        KeychainHelper.delete(for: keychainAccount)
    }
}
