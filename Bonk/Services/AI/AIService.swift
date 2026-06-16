import Foundation
import Observation
import os.log

/// AI service that provides terminal assistance features.
@Observable @MainActor
final class AIService {
    static let shared = AIService()

    var currentExplanation: String?
    var isProcessing = false
    var lastError: String?
    var streamingResponse: String = ""

    /// Active provider — set by views that have access to AIProviderStore.
    var activeProvider: AIProviderConfig?

    // MARK: - Public API

    func chat(_ message: String, context _: TerminalContext) async {
        let systemPrompt = """
        You are a terminal assistant embedded in an SSH client.
        Answer concisely. Use markdown formatting:
        - Use fenced code blocks (triple backticks with bash) for commands
        - Use bold for emphasis
        - Use inline code for file paths and flags
        No greetings or filler. Match the user's language.
        """
        await execute(systemPrompt: systemPrompt, userPrompt: message, label: "chat")
    }

    func explainError(_ errorOutput: String, context _: TerminalContext) async {
        let systemPrompt = """
        You are a terminal error diagnoser embedded in an SSH client.
        Explain the error briefly and suggest a fix. \
        Reply in plain text, no markdown.
        Match the user's language.
        """
        let userPrompt = "Explain this terminal error:\n\n\(errorOutput)"
        await execute(systemPrompt: systemPrompt, userPrompt: userPrompt, label: "explainError")
    }

    // MARK: - Core

    private func execute(systemPrompt: String, userPrompt: String, label: String) async {
        guard let (provider, apiKey) = resolveProvider() else { return }

        let modelLower = provider.model.lowercased()
        if modelLower.contains("safety") || modelLower.contains("classifier") {
            lastError = L.t(.dangerousCommand) + ": \(provider.model)"
            Log.ai.error("\(label): safety classifier: \(provider.model)")
            return
        }

        isProcessing = true
        streamingResponse = ""
        defer { isProcessing = false }

        Log.ai.info("\(label): provider=\(provider.name, privacy: .public) model=\(provider.model, privacy: .public)")

        let maxRetries = 2
        for attempt in 0 ... maxRetries {
            do {
                let response = try await AIProviderNetworking.streamRequest(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: systemPrompt, userPrompt: userPrompt
                ) { [weak self] delta in
                    self?.streamingResponse += delta
                }
                let sanitized = AIOutputSanitizer.sanitize(response)
                if sanitized != response {
                    Log.ai.warning("\(label): output sanitized (contained dangerous content)")
                }
                Log.ai.info("\(label): response(\(sanitized.count) chars)")
                if !Task.isCancelled { currentExplanation = sanitized }
                return
            } catch {
                if Task.isCancelled { return }
                if let aiError = error as? AIError, !aiError.isRetryable {
                    lastError = error.localizedDescription
                    Log.ai.error("\(label): non-retryable: \(error.localizedDescription, privacy: .public)")
                    return
                }
                if attempt < maxRetries {
                    Log.ai.warning("\(label): attempt \(attempt + 1) failed, retrying")
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                } else {
                    lastError = error.localizedDescription
                    Log.ai.error("\(label): all attempts failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func resolveProvider() -> (AIProviderConfig, String)? {
        guard let provider = activeProvider else {
            lastError = L.t(.noActiveProvider)
            return nil
        }
        let key = provider.apiKey
        guard !key.isEmpty else {
            lastError = String(format: L.t(.apiKeyNotSet), provider.name)
            return nil
        }
        return (provider, key)
    }
}

// MARK: - Shared Types

struct TerminalContext {
    var currentDirectory: String?
    var shell: String?
    var recentCommands: [String] = []
    var terminalOutput: String?
}

enum AIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid AI provider endpoint"
        case .invalidResponse: "Invalid response from AI provider"
        case let .apiError(code, msg): "AI API error (\(code)): \(msg)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .invalidEndpoint, .invalidResponse: false
        case let .apiError(code, _): code >= 500
        }
    }
}
