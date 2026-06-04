import Foundation

/// Supported AI provider types with their default configurations.
enum AIProviderType: String, CaseIterable, Identifiable, Codable {
    case copilot, claude, openAI, openRouter, openCode, gemini, ollama, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copilot:    return "GitHub Copilot"
        case .claude:     return "Claude"
        case .openAI:     return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .openCode:   return "OpenCode Zen"
        case .gemini:     return "Gemini"
        case .ollama:     return "Ollama"
        case .custom:     return I18n.shared.t(.custom)
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .copilot:    return ""
        case .claude:     return "https://api.anthropic.com"
        case .openAI:     return "https://api.openai.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .openCode:   return "https://opencode.ai/zen"
        case .gemini:     return "https://generativelanguage.googleapis.com"
        case .ollama:     return "http://localhost:11434"
        case .custom:     return ""
        }
    }

    var symbolName: String {
        switch self {
        case .copilot:    return "chevron.left.forwardslash.chevron.right"
        case .claude:     return "brain"
        case .openAI:     return "cpu"
        case .openRouter: return "globe"
        case .openCode:   return "sparkles"
        case .gemini:     return "wand.and.stars"
        case .ollama:     return "desktopcomputer"
        case .custom:     return "server.rack"
        }
    }

    var defaultModel: String {
        switch self {
        case .copilot:    return ""
        case .claude:     return "claude-sonnet-4-20250514"
        case .openAI:     return "gpt-4o"
        case .openRouter: return "anthropic/claude-sonnet-4-20250514"
        case .openCode:   return ""
        case .gemini:     return "gemini-2.5-flash"
        case .ollama:     return "llama3"
        case .custom:     return ""
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .ollama, .copilot, .openCode: return false
        default: return true
        }
    }
}
