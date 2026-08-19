import Foundation

/// Reads model metadata when an OpenAI-compatible endpoint exposes it.
/// Probe never sends a completion request, so it cannot consume model tokens.
enum AIProviderCapabilityProbe {
    static func refresh(
        provider: AIProviderConfig,
        apiKey: String,
        now: Date = Date()
    ) async {
        guard supportsMetadataProbe(provider.type) else { return }
        guard AIProviderCapabilityCache.snapshot(for: provider, now: now) == nil else {
            return
        }

        do {
            guard let url = AIProviderNetworking.modelsURL(
                endpoint: provider.endpoint,
                type: provider.type
            ) else {
                throw AIError.invalidEndpoint
            }

            let request = AIProviderNetworking.makeRequest(
                url: url,
                apiKey: apiKey,
                type: provider.type,
                extraHeaders: provider.extraHeaders
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.invalidResponse
            }
            guard http.statusCode < 400 else {
                throw AIError.apiError(
                    statusCode: http.statusCode,
                    message: String(data: data.prefix(300), encoding: .utf8) ?? ""
                )
            }

            guard let snapshot = try parse(
                data: data,
                provider: provider,
                now: now
            ) else {
                throw AIError.invalidResponse
            }
            AIProviderCapabilityCache.store(snapshot, for: provider)
        } catch {
            // Probe is advisory. A failed probe must never block normal chat.
            AIProviderCapabilityCache.recordFailure(error, for: provider, now: now)
        }
    }

    static func parse(
        data: Data,
        provider: AIProviderConfig,
        now: Date = Date()
    ) throws -> AICapabilitySnapshot? {
        guard let root = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else {
            throw AIError.invalidResponse
        }

        let wanted = provider.model.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !wanted.isEmpty else { return nil }
        let entry = entries.first {
            guard let id = $0["id"] as? String else { return false }
            return id == wanted
        }
        guard let entry else { return nil }

        let baseline = AIProviderCapabilityResolver.builtinCapability(
            for: provider
        ) ?? AIProviderCapabilityResolver.providerDefaultCapability(
            for: provider
        )
        var capability = baseline
        var evidence = false

        if let value = bool(in: entry, keys: [
            "supports_chat_completions", "supportsChatCompletions",
        ]) {
            capability.supportsChatCompletions = value
            evidence = true
        }
        if let value = bool(in: entry, keys: [
            "supports_responses", "supportsResponses", "responses",
        ]) {
            capability.supportsResponses = value
            evidence = true
        }
        if let value = bool(in: entry, keys: [
            "supports_streaming", "supportsStreaming", "streaming",
        ]) {
            capability.supportsStreaming = value
            evidence = true
        }
        if let value = bool(in: entry, keys: [
            "supports_tool_calls", "supportsToolCalls", "tool_calls", "tools",
        ]) {
            capability.supportsToolCalls = value
            evidence = true
        } else if let parameters = entry["supported_parameters"] as? [String] {
            let lower = Set(parameters.map { $0.lowercased() })
            if lower.contains("tools") || lower.contains("tool_choice") {
                capability.supportsToolCalls = true
                evidence = true
            }
        }

        if let reasoning = string(in: entry, keys: [
            "reasoning_support", "reasoningSupport",
        ]) {
            switch reasoning.lowercased() {
            case "required":
                capability.reasoningSupport = .required
            case "optional", "supported":
                capability.reasoningSupport = .optional
            case "unsupported", "none", "disabled":
                capability.reasoningSupport = .unsupported
            default:
                break
            }
            evidence = true
        }
        if let value = bool(in: entry, keys: [
            "can_disable_reasoning", "canDisableReasoning",
        ]) {
            capability.canDisableReasoning = value
            evidence = true
        }

        // Metadata often exposes supported_parameters but omits generic
        // streaming/chat flags. OpenAI-compatible model listings imply Chat.
        if entry["supported_parameters"] != nil {
            capability.supportsChatCompletions = true
            evidence = true
        }

        guard evidence else { return nil }
        let confidence: AICapabilityConfidence =
            capability.supportsResponses != baseline.supportsResponses
                ? .high
                : .medium
        return AICapabilitySnapshot(
            capability: capability,
            source: .dynamicProbe,
            confidence: confidence,
            checkedAt: now,
            expiresAt: now.addingTimeInterval(
                AIProviderCapabilityCache.defaultTTL
            ),
            failureReason: nil
        )
    }

    private static func supportsMetadataProbe(_ type: AIProviderType) -> Bool {
        switch type {
        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .custom:
            true
        case .claude, .gemini, .ollama:
            false
        }
    }

    private static func bool(
        in dictionary: [String: Any],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool {
                return value
            }
        }
        for containerKey in ["capabilities", "metadata"] {
            if let nested = dictionary[containerKey] as? [String: Any],
               let value = bool(in: nested, keys: keys)
            {
                return value
            }
        }
        return nil
    }

    private static func string(
        in dictionary: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }
        for containerKey in ["capabilities", "metadata"] {
            if let nested = dictionary[containerKey] as? [String: Any],
               let value = string(in: nested, keys: keys)
            {
                return value
            }
        }
        return nil
    }
}
