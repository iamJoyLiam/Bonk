import Foundation

/// Builds the right provider adapter for a saved config. Agent Runtime and the
/// settings UI both go through here — no caller branches on provider type.
enum LLMProviderFactory {
    static func provider(for config: AIProviderConfig, apiKey: String) -> any LLMProvider {
        switch config.type {
        case .claude:
            ClaudeLLMProvider(config: config, apiKey: apiKey)
        case .gemini:
            GeminiLLMProvider(config: config, apiKey: apiKey)
        case .ollama:
            OllamaLLMProvider(config: config, apiKey: apiKey)
        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .custom:
            if config.protocolType == .responses {
                OpenAIResponsesLLMProvider(config: config, apiKey: apiKey)
            } else {
                OpenAICompatibleLLMProvider(config: config, apiKey: apiKey)
            }
        }
    }
}
