import Foundation

/// Builds the right provider adapter for a saved config. Agent Runtime and the
/// settings UI both go through here — no caller branches on provider type.
/// How a saved provider config becomes a live provider.
///
/// Exists so the agent can be given a provider without reaching for a static
/// factory mid-method. The default implementation is `LLMProviderFactory`
/// verbatim, so production behaviour is unchanged by construction — this adds
/// observability, not a new production path. Anything that re-introduces a
/// direct `LLMProviderFactory.provider(...)` call inside `AgentEngine` is a
/// regression the provider-boundary tests are meant to catch.
protocol LLMProviderResolving: Sendable {
    func provider(
        for config: AIProviderConfig,
        apiKey: String,
        workload: AIWorkload
    ) -> any LLMProvider
}

struct DefaultLLMProviderResolver: LLMProviderResolving {
    func provider(
        for config: AIProviderConfig,
        apiKey: String,
        workload: AIWorkload
    ) -> any LLMProvider {
        LLMProviderFactory.provider(for: config, apiKey: apiKey, workload: workload)
    }
}

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
