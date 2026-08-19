import Foundation

/// Builds the right provider adapter for a saved config. Agent Runtime and the
/// settings UI both go through here — no caller branches on provider type.
enum LLMProviderFactory {
    static func provider(for config: AIProviderConfig, apiKey: String) -> any LLMProvider {
        provider(for: config, apiKey: apiKey, workload: .chat)
    }

    static func provider(
        for config: AIProviderConfig,
        apiKey: String,
        workload: AIWorkload
    ) -> any LLMProvider {
        let route = AIProviderCapabilityResolver.resolve(
            config: config, workload: workload
        )

        switch route.wireProtocol {
        case .anthropicMessages:
            return ClaudeLLMProvider(
                config: config, apiKey: apiKey, capability: route.capability
            )
        case .geminiNative:
            return GeminiLLMProvider(
                config: config, apiKey: apiKey, capability: route.capability
            )
        case .ollamaOpenAICompatible, .ollamaNative:
            return OllamaLLMProvider(
                config: config, apiKey: apiKey, capability: route.capability
            )
        case .openAIResponses:
            return OpenAIResponsesLLMProvider(
                config: config, apiKey: apiKey, capability: route.capability
            )
        case .openAIChatCompletions:
            return OpenAICompatibleLLMProvider(
                config: config, apiKey: apiKey, capability: route.capability
            )
        }
    }

}
