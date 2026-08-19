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
    /// Optional additive fields — safe for SwiftData migration.
    var protocolRaw: String?
    var capabilityOverrideJSON: String?
    var extraHeadersJSON: String?
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

    var protocolType: AIProviderProtocol {
        get {
            let stored = AIProviderProtocol(rawValue: protocolRaw ?? "")
                ?? type.defaultProtocolType
            return type.supportsResponses ? stored : .chatCompletions
        }
        set { protocolRaw = newValue.rawValue }
    }

    var capabilityOverride: ModelCapabilityOverride? {
        get {
            guard let capabilityOverrideJSON,
                  let data = capabilityOverrideJSON.data(using: .utf8)
            else { return nil }
            return try? JSONDecoder().decode(ModelCapabilityOverride.self, from: data)
        }
        set {
            capabilityOverrideJSON = newValue.flatMap { override in
                guard let data = try? JSONEncoder().encode(override) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }
    }

    var extraHeaders: [String: String] {
        get {
            guard let extraHeadersJSON,
                  let data = extraHeadersJSON.data(using: .utf8),
                  let headers = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return headers
        }
        set {
            extraHeadersJSON = newValue.isEmpty
                ? nil
                : (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        type: AIProviderType = .claude,
        model: String = "",
        endpoint: String = "",
        protocolType: AIProviderProtocol? = nil,
        capabilityOverride: ModelCapabilityOverride? = nil,
        extraHeaders: [String: String] = [:],
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
        let resolvedProtocol = protocolType ?? type.defaultProtocolType
        self.protocolRaw = (type.supportsResponses ? resolvedProtocol : .chatCompletions).rawValue
        self.capabilityOverrideJSON = capabilityOverride.flatMap { override in
            guard let data = try? JSONEncoder().encode(override) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        self.extraHeadersJSON = extraHeaders.isEmpty
            ? nil
            : (try? JSONEncoder().encode(extraHeaders)).flatMap { String(data: $0, encoding: .utf8) }
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
