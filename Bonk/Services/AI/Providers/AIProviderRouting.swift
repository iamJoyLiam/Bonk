import Foundation

/// Request workload. Same provider may need different model/latency policy
/// for chat, agent tools, and inline completion.
enum AIWorkload: String, Codable, Hashable, Sendable {
    case chat
    case agentToolLoop
    case inlineCompletion
}

/// Wire protocol used by adapter. Capability describes what model can do;
/// protocol describes how request must be encoded.
enum AIWireProtocol: String, Codable, Hashable, Sendable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages
    case geminiNative
    case ollamaOpenAICompatible
    case ollamaNative
}

enum AIReasoningSupport: String, Codable, Hashable, Sendable {
    case unsupported
    case optional
    case required
}

enum AIReasoningDisableStrategy: String, Codable, Hashable, Sendable {
    case none
    case deepSeekThinkingDisabled
    case enableThinkingFalse
}

enum AICapabilityConfidence: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high
}

/// Model-level capability. Defaults stay conservative for new protocols.
struct ModelCapability: Codable, Equatable, Hashable, Sendable {
    var supportsChatCompletions: Bool
    var supportsResponses: Bool
    var supportsStreaming: Bool
    var supportsToolCalls: Bool
    var reasoningSupport: AIReasoningSupport
    var canDisableReasoning: Bool
    var reasoningDisableStrategy: AIReasoningDisableStrategy

    init(
        supportsChatCompletions: Bool = false,
        supportsResponses: Bool = false,
        supportsStreaming: Bool = false,
        supportsToolCalls: Bool = false,
        reasoningSupport: AIReasoningSupport = .unsupported,
        canDisableReasoning: Bool = false,
        reasoningDisableStrategy: AIReasoningDisableStrategy = .none
    ) {
        self.supportsChatCompletions = supportsChatCompletions
        self.supportsResponses = supportsResponses
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalls = supportsToolCalls
        self.reasoningSupport = reasoningSupport
        self.canDisableReasoning = canDisableReasoning
        self.reasoningDisableStrategy = reasoningDisableStrategy
    }

    /// Compatibility initializer for existing provider adapters.
    init(supportsStreaming: Bool, supportsToolCalls: Bool) {
        self.init(
            supportsChatCompletions: true,
            supportsStreaming: supportsStreaming,
            supportsToolCalls: supportsToolCalls
        )
    }
}

/// Partial user override. Nil fields keep resolver defaults.
struct ModelCapabilityOverride: Codable, Equatable, Hashable, Sendable {
    var supportsChatCompletions: Bool?
    var supportsResponses: Bool?
    var supportsStreaming: Bool?
    var supportsToolCalls: Bool?
    var reasoningSupport: AIReasoningSupport?
    var canDisableReasoning: Bool?
    var reasoningDisableStrategy: AIReasoningDisableStrategy?

    init(
        supportsChatCompletions: Bool? = nil,
        supportsResponses: Bool? = nil,
        supportsStreaming: Bool? = nil,
        supportsToolCalls: Bool? = nil,
        reasoningSupport: AIReasoningSupport? = nil,
        canDisableReasoning: Bool? = nil,
        reasoningDisableStrategy: AIReasoningDisableStrategy? = nil
    ) {
        self.supportsChatCompletions = supportsChatCompletions
        self.supportsResponses = supportsResponses
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalls = supportsToolCalls
        self.reasoningSupport = reasoningSupport
        self.canDisableReasoning = canDisableReasoning
        self.reasoningDisableStrategy = reasoningDisableStrategy
    }

    var isEmpty: Bool {
        supportsChatCompletions == nil
            && supportsResponses == nil
            && supportsStreaming == nil
            && supportsToolCalls == nil
            && reasoningSupport == nil
            && canDisableReasoning == nil
            && reasoningDisableStrategy == nil
    }
}

extension ModelCapability {
    func applying(_ override: ModelCapabilityOverride) -> ModelCapability {
        ModelCapability(
            supportsChatCompletions: override.supportsChatCompletions ?? supportsChatCompletions,
            supportsResponses: override.supportsResponses ?? supportsResponses,
            supportsStreaming: override.supportsStreaming ?? supportsStreaming,
            supportsToolCalls: override.supportsToolCalls ?? supportsToolCalls,
            reasoningSupport: override.reasoningSupport ?? reasoningSupport,
            canDisableReasoning: override.canDisableReasoning ?? canDisableReasoning,
            reasoningDisableStrategy: override.reasoningDisableStrategy
                ?? reasoningDisableStrategy
        )
    }
}

enum AICapabilitySource: String, Codable, Hashable, Sendable {
    case providerDefault
    case builtinModel
    case dynamicProbe
    case userOverride
}

struct AIProviderRoute: Equatable, Sendable {
    let wireProtocol: AIWireProtocol
    let capability: ModelCapability
    let source: AICapabilitySource
    let confidence: AICapabilityConfidence?
    let checkedAt: Date?
}

/// Capability result persisted after endpoint metadata probing.
struct AICapabilitySnapshot: Codable, Equatable, Sendable {
    var capability: ModelCapability
    var source: AICapabilitySource
    var confidence: AICapabilityConfidence
    var checkedAt: Date
    var expiresAt: Date
    var failureReason: String?

    var isFresh: Bool {
        isFresh(at: Date())
    }

    func isFresh(at date: Date) -> Bool {
        expiresAt > date
    }
}

/// Small UserDefaults-backed cache. It avoids another SwiftData model while
/// keeping probe TTL/failure metadata explicit and easy to remove or migrate.
enum AIProviderCapabilityCache {
    private static let storageKey = "ai_provider_capability_snapshots_v1"
    static let defaultTTL: TimeInterval = 24 * 60 * 60
    static let failureTTL: TimeInterval = 15 * 60

    static func key(for config: AIProviderConfig) -> String {
        [
            config.id.uuidString,
            AIProviderNetworking.baseEndpoint(config.endpoint),
            config.type.rawValue,
            config.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: "\u{1F}")
    }

    static func snapshot(
        for config: AIProviderConfig,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> AICapabilitySnapshot? {
        let records = load(defaults: defaults)
        guard let record = records[key(for: config)] else { return nil }
        guard record.isFresh(at: now) else {
            var updated = records
            updated.removeValue(forKey: key(for: config))
            save(updated, defaults: defaults)
            return nil
        }
        return record
    }

    static func store(
        _ snapshot: AICapabilitySnapshot,
        for config: AIProviderConfig,
        defaults: UserDefaults = .standard
    ) {
        var records = load(defaults: defaults)
        records[key(for: config)] = snapshot
        save(records, defaults: defaults)
    }

    static func recordFailure(
        _ error: Error,
        for config: AIProviderConfig,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let baseline = AIProviderCapabilityResolver.providerDefaultCapability(for: config)
        let snapshot = AICapabilitySnapshot(
            capability: baseline,
            source: .dynamicProbe,
            confidence: .low,
            checkedAt: now,
            expiresAt: now.addingTimeInterval(failureTTL),
            failureReason: error.localizedDescription
        )
        store(snapshot, for: config, defaults: defaults)
    }

    static func clear(
        for config: AIProviderConfig,
        defaults: UserDefaults = .standard
    ) {
        var records = load(defaults: defaults)
        records.removeValue(forKey: key(for: config))
        save(records, defaults: defaults)
    }

    private static func load(
        defaults: UserDefaults
    ) -> [String: AICapabilitySnapshot] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode(
                [String: AICapabilitySnapshot].self, from: data
              )
        else { return [:] }
        return records
    }

    private static func save(
        _ records: [String: AICapabilitySnapshot],
        defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Resolver. `protocolType` remains user preference; capability decides which
/// protocol is legal. Dynamic probe > builtin model table > provider default,
/// then user override wins.
enum AIProviderCapabilityResolver {
    static func resolve(
        config: AIProviderConfig,
        workload: AIWorkload,
        now: Date = Date()
    ) -> AIProviderRoute {
        var capability = providerDefaultCapability(for: config)
        var source: AICapabilitySource = .providerDefault
        var confidence: AICapabilityConfidence?
        var checkedAt: Date?

        if let builtin = builtinCapability(for: config) {
            capability = builtin
            source = .builtinModel
            confidence = .medium
        }

        if let snapshot = AIProviderCapabilityCache.snapshot(
            for: config, now: now
        ), snapshot.failureReason == nil {
            capability = snapshot.capability
            source = snapshot.source
            confidence = snapshot.confidence
            checkedAt = snapshot.checkedAt
        }

        if let override = config.capabilityOverride {
            capability = capability.applying(override)
            source = .userOverride
            confidence = .high
        }

        let wireProtocol = protocolFor(
            config, capability: capability, workload: workload
        )
        return AIProviderRoute(
            wireProtocol: wireProtocol,
            capability: capability,
            source: source,
            confidence: confidence,
            checkedAt: checkedAt
        )
    }

    static func protocolFor(
        _ config: AIProviderConfig,
        capability: ModelCapability,
        workload: AIWorkload
    ) -> AIWireProtocol {
        switch config.type {
        case .claude:
            return .anthropicMessages
        case .gemini:
            return .geminiNative
        case .ollama:
            return .ollamaOpenAICompatible
        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .custom:
            switch workload {
            case .inlineCompletion:
                // Chat streaming has lower overhead than Responses for ghost
                // text. Use Responses only when Chat is unavailable.
                if capability.supportsChatCompletions {
                    return .openAIChatCompletions
                }
                return capability.supportsResponses
                    ? .openAIResponses
                    : .openAIChatCompletions
            case .agentToolLoop:
                // Tool loop follows user's preference only when selected wire
                // protocol advertises tool calls. Otherwise use legal fallback.
                if config.protocolType == .responses,
                   capability.supportsResponses,
                   capability.supportsToolCalls
                {
                    return .openAIResponses
                }
                if capability.supportsChatCompletions {
                    return .openAIChatCompletions
                }
                return capability.supportsResponses
                    ? .openAIResponses
                    : .openAIChatCompletions
            case .chat:
                if config.protocolType == .responses, capability.supportsResponses {
                    return .openAIResponses
                }
                if capability.supportsChatCompletions {
                    return .openAIChatCompletions
                }
                return capability.supportsResponses
                    ? .openAIResponses
                    : .openAIChatCompletions
            }
        }
    }

    static func providerDefaultCapability(
        for config: AIProviderConfig
    ) -> ModelCapability {
        switch config.type {
        case .claude:
            return ModelCapability(
                supportsStreaming: true,
                reasoningSupport: .optional
            )
        case .gemini:
            return ModelCapability(
                supportsStreaming: false,
                reasoningSupport: .optional
            )
        case .ollama:
            return ModelCapability(
                supportsChatCompletions: true,
                supportsStreaming: true
            )
        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .custom:
            let supportsResponses = config.protocolType == .responses
                && config.type.supportsResponses
            return ModelCapability(
                supportsChatCompletions: true,
                supportsResponses: supportsResponses,
                supportsStreaming: true,
                supportsToolCalls: true,
                reasoningSupport: reasoningSupport(for: config.type),
                canDisableReasoning: canDisableReasoning(for: config.type),
                reasoningDisableStrategy: reasoningDisableStrategy(for: config.type)
            )
        }
    }

    static func builtinCapability(
        for config: AIProviderConfig
    ) -> ModelCapability? {
        let model = config.model.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !model.isEmpty else { return nil }

        switch config.type {
        case .openAI:
            guard model.hasPrefix("gpt-") || model.hasPrefix("o1")
                || model.hasPrefix("o3") || model.hasPrefix("o4")
            else { return nil }
            return ModelCapability(
                supportsChatCompletions: true,
                supportsResponses: true,
                supportsStreaming: true,
                supportsToolCalls: true,
                reasoningSupport: model.hasPrefix("o")
                    ? .optional : .unsupported
            )
        case .openRouter where model.hasPrefix("openai/"):
            return ModelCapability(
                supportsChatCompletions: true,
                supportsResponses: true,
                supportsStreaming: true,
                supportsToolCalls: true,
                reasoningSupport: model.contains("/o")
                    ? .optional : .unsupported
            )
        case .deepSeek:
            return ModelCapability(
                supportsChatCompletions: true,
                supportsStreaming: true,
                supportsToolCalls: true,
                reasoningSupport: .optional,
                canDisableReasoning: true,
                reasoningDisableStrategy: .deepSeekThinkingDisabled
            )
        case .qwen:
            return ModelCapability(
                supportsChatCompletions: true,
                supportsStreaming: true,
                supportsToolCalls: true,
                reasoningSupport: .optional,
                canDisableReasoning: true,
                reasoningDisableStrategy: .enableThinkingFalse
            )
        case .kimi:
            return ModelCapability(
                supportsChatCompletions: true,
                supportsStreaming: true,
                supportsToolCalls: true,
                reasoningSupport: .optional,
                canDisableReasoning: true,
                reasoningDisableStrategy: .enableThinkingFalse
            )
        default:
            return nil
        }
    }

    private static func reasoningSupport(for type: AIProviderType) -> AIReasoningSupport {
        switch type {
        case .deepSeek, .qwen, .kimi:
            .optional
        default:
            .unsupported
        }
    }

    private static func canDisableReasoning(for type: AIProviderType) -> Bool {
        switch type {
        case .deepSeek, .qwen, .kimi:
            true
        default:
            false
        }
    }

    private static func reasoningDisableStrategy(
        for type: AIProviderType
    ) -> AIReasoningDisableStrategy {
        switch type {
        case .deepSeek:
            .deepSeekThinkingDisabled
        case .qwen, .kimi:
            .enableThinkingFalse
        default:
            .none
        }
    }
}
