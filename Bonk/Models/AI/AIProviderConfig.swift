import Foundation

/// Configuration for an AI provider instance.
/// API key is stored in Keychain, not in UserDefaults.
struct AIProviderConfig: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var type: AIProviderType
    var model: String
    var endpoint: String
    var protocolType: AIProviderProtocol
    var extraHeaders: [String: String]
    var maxOutputTokens: Int?
    var telemetryEnabled: Bool

    /// Exclude apiKey from Codable — stored in Keychain
    enum CodingKeys: String, CodingKey {
        case id, name, type, model, endpoint, protocolType, extraHeaders, maxOutputTokens, telemetryEnabled
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
        protocolType: AIProviderProtocol? = nil,
        extraHeaders: [String: String] = [:],
        apiKey: String = "",
        maxOutputTokens: Int? = nil,
        telemetryEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.model = model
        self.endpoint = endpoint.isEmpty ? type.defaultEndpoint : endpoint
        let resolvedProtocol = protocolType ?? type.defaultProtocolType
        self.protocolType = type.supportsResponses ? resolvedProtocol : .chatCompletions
        self.extraHeaders = extraHeaders
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

// MARK: - Codable back-compat (older saved configs lack protocol/headers)

extension AIProviderConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(AIProviderType.self, forKey: .type)
        model = try container.decode(String.self, forKey: .model)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        let decodedProtocol = try container.decodeIfPresent(AIProviderProtocol.self, forKey: .protocolType)
            ?? type.defaultProtocolType
        protocolType = type.supportsResponses ? decodedProtocol : .chatCompletions
        extraHeaders = try container.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled) ?? false
        if endpoint.isEmpty { endpoint = type.defaultEndpoint }
    }
}
