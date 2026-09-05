import Foundation

/// Supported AI provider types with their default configurations.
enum AIProviderType: String, CaseIterable, Identifiable, Codable {
    case claude, openAI, openRouter, openCode, deepSeek, qwen, kimi, gemini, ollama, custom

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .openCode: "OpenCode Zen"
        case .deepSeek: "DeepSeek"
        case .qwen: "Qwen"
        case .kimi: "Kimi"
        case .gemini: "Gemini"
        case .ollama: "Ollama"
        case .custom: I18n.shared.t(.custom)
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .claude: "https://api.anthropic.com"
        case .openAI: "https://api.openai.com"
        case .openRouter: "https://openrouter.ai/api"
        case .openCode: "https://opencode.ai/zen"
        case .deepSeek: "https://api.deepseek.com"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode"
        case .kimi: "https://api.moonshot.cn"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .ollama: "http://localhost:11434"
        case .custom: ""
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "brain"
        case .openAI: "cpu"
        case .openRouter: "globe"
        case .openCode: "sparkles"
        case .deepSeek: "waveform.path.ecg"
        case .qwen: "cloud.fill"
        case .kimi: "moon.stars.fill"
        case .gemini: "wand.and.stars"
        case .ollama: "desktopcomputer"
        case .custom: "server.rack"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: "claude-sonnet-5"
        case .openAI: "gpt-5.6-terra"
        case .openRouter: "anthropic/claude-sonnet-5"
        case .openCode: ""
        case .deepSeek: "deepseek-v4-flash"
        case .qwen: "qwen3.8-max"
        case .kimi: "kimi-k3"
        case .gemini: "gemini-3.5-flash"
        case .ollama: "llama3"
        case .custom: ""
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .ollama, .custom: false
        default: true
        }
    }

    /// Whether the provider has a working `/v1/responses` implementation.
    /// Used to decide where the protocol switch is shown and to guard old
    /// saved configs that selected Responses on a provider that never
    /// supported it.
    var supportsResponses: Bool {
        switch self {
        case .claude, .gemini, .kimi, .ollama: false
        default: true
        }
    }

    /// OpenAI's own endpoint is Responses-first today, so new OpenAI configs
    /// default there and the protocol picker is hidden (Chat Completions is
    /// still supported, but no longer the recommended default). Third-party
    /// OpenAI-compatible providers stay on Chat Completions unless the server
    /// explicitly implements `/v1/responses`.
    var defaultProtocolType: AIProviderProtocol {
        switch self {
        case .openAI: .responses
        default: .chatCompletions
        }
    }

    /// Which configs expose the Chat Completions / Responses API switch.
    /// OpenAI is Responses-first by design; Claude/Gemini don't speak either
    /// protocol, and Kimi/Ollama only implement Chat Completions, so no
    /// switch there either.
    var allowsProtocolSelection: Bool {
        supportsResponses && self != .openAI
    }

}
