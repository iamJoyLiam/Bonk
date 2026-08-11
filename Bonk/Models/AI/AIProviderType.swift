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
        case .claude: "claude-sonnet-4-20250514"
        case .openAI: "gpt-4o"
        case .openRouter: "anthropic/claude-sonnet-4-20250514"
        case .openCode: ""
        case .deepSeek: "deepseek-v4-flash"
        case .qwen: "qwen-plus"
        case .kimi: "kimi-k2"
        case .gemini: "gemini-2.5-flash"
        case .ollama: "llama3"
        case .custom: ""
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .ollama, .openCode: false
        default: true
        }
    }
}
