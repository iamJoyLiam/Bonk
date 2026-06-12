import Foundation

/// Supported AI provider types with their default configurations.
enum AIProviderType: String, CaseIterable, Identifiable, Codable {
    case copilot, claude, openAI, openRouter, openCode, gemini, ollama, custom

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .copilot: "GitHub Copilot"
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .openCode: "OpenCode Zen"
        case .gemini: "Gemini"
        case .ollama: "Ollama"
        case .custom: I18n.shared.t(.custom)
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .copilot: ""
        case .claude: "https://api.anthropic.com"
        case .openAI: "https://api.openai.com"
        case .openRouter: "https://openrouter.ai/api"
        case .openCode: "https://opencode.ai/zen"
        case .gemini: "https://generativelanguage.googleapis.com"
        case .ollama: "http://localhost:11434"
        case .custom: ""
        }
    }

    var symbolName: String {
        switch self {
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .claude: "brain"
        case .openAI: "cpu"
        case .openRouter: "globe"
        case .openCode: "sparkles"
        case .gemini: "wand.and.stars"
        case .ollama: "desktopcomputer"
        case .custom: "server.rack"
        }
    }

    var defaultModel: String {
        switch self {
        case .copilot: ""
        case .claude: "claude-sonnet-4-20250514"
        case .openAI: "gpt-4o"
        case .openRouter: "anthropic/claude-sonnet-4-20250514"
        case .openCode: ""
        case .gemini: "gemini-2.5-flash"
        case .ollama: "llama3"
        case .custom: ""
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .ollama, .copilot, .openCode: false
        default: true
        }
    }
}
