//
//  AIService.swift
//  Bonk
//
//  AI service layer that connects AI providers to terminal features.
//

import Foundation
import SwiftUI
import os.log

/// AI service that provides terminal assistance features.
@Observable @MainActor
final class AIService {
    /// Shared instance.
    static let shared = AIService()

    /// Error explanation from AI.
    var currentExplanation: String?

    /// Whether AI is currently processing.
    var isProcessing = false

    /// Last error message.
    var lastError: String?

    /// Streaming response (incremental).
    var streamingResponse: String = ""

    /// General chat with AI - for questions, not just errors.
    func chat(_ message: String, context: TerminalContext) async {
        guard let provider = activeProvider else {
            lastError = "No active AI provider configured"
            Log.ai.error("chat: no active provider")
            return
        }

        let apiKey = provider.apiKey
        guard !apiKey.isEmpty else {
            lastError = "API key not set for \(provider.name)"
            Log.ai.error("chat: no API key for \(provider.name)")
            return
        }

        // Check for safety/classifier models that aren't chat models
        let modelLower = provider.model.lowercased()
        if modelLower.contains("safety") || modelLower.contains("classifier") || modelLower.contains("content-safety") {
            lastError = "当前模型「\(provider.model)」是安全分类器，不是对话模型。请在设置中更换为对话模型（如 gpt-4o、claude-sonnet-4-20250514、deepseek-chat 等）"
            Log.ai.error("chat: safety classifier model detected: \(provider.model)")
            return
        }

        isProcessing = true
        streamingResponse = ""
        defer { isProcessing = false }

        let systemPrompt = """
        You are a terminal assistant embedded in an SSH client.
        Answer concisely in plain text. If providing a command, show it on its own line.
        No greetings or filler. Match the user's language.
        """

        Log.ai.info("chat: provider=\(provider.name) model=\(provider.model) msg=\(message.prefix(80))")

        do {
            let response = try await callAIProviderStreaming(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: message,
                maxTokens: 500
            )

            Log.ai.info("chat: response(\(response.count) chars)=\(response.prefix(200))")

            if !Task.isCancelled {
                currentExplanation = response
            }
        } catch {
            lastError = error.localizedDescription
            Log.ai.error("chat: error=\(error.localizedDescription)")
        }
    }

    /// Explain an error from terminal output.
    func explainError(_ errorOutput: String, context: TerminalContext) async {
        guard let provider = activeProvider else {
            lastError = "No active AI provider configured"
            Log.ai.error("explainError: no active provider")
            return
        }

        let apiKey = provider.apiKey
        guard !apiKey.isEmpty else {
            lastError = "API key not set for \(provider.name)"
            Log.ai.error("explainError: no API key for \(provider.name)")
            return
        }

        isProcessing = true
        streamingResponse = ""
        defer { isProcessing = false }

        let systemPrompt = """
        You are a terminal error diagnoser embedded in an SSH client.
        Explain the error briefly and suggest a fix. Reply in plain text, no markdown.
        Match the user's language.
        """

        let userPrompt = """
        Explain this terminal error:

        \(errorOutput)
        """

        do {
            // Try streaming first
            let response = try await callAIProviderStreaming(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 500
            )

            if !Task.isCancelled {
                currentExplanation = response
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Get the active AI provider from UserDefaults.
    private var activeProvider: AIProviderConfig? {
        guard let data = UserDefaults.standard.data(forKey: "ai_providers"),
              let providers = try? JSONDecoder().decode([AIProviderConfig].self, from: data),
              let activeId = UserDefaults.standard.string(forKey: "ai_active_provider_id"),
              let provider = providers.first(where: { $0.id.uuidString == activeId }) else {
            return nil
        }
        return provider
    }

    /// Call the AI provider's API.
    private func callAIProvider(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        let endpoint = provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        guard !endpoint.isEmpty else {
            throw AIError.invalidEndpoint
        }

        let url: URL
        let headers: [String: String]
        let body: [String: Any]

        switch provider.type {
        case .claude:
            url = URL(string: "\(endpoint)/v1/messages")!
            headers = [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json"
            ]
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ]
            ]

        case .openAI, .openRouter, .copilot, .openCode, .custom:
            url = URL(string: "\(endpoint)/v1/chat/completions")!
            headers = [
                "Authorization": "Bearer \(apiKey)",
                "content-type": "application/json"
            ]
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]

        case .gemini:
            url = URL(string: "\(endpoint)/v1beta/models/\(provider.model):generateContent")!
            headers = [
                "x-goog-api-key": apiKey,
                "content-type": "application/json"
            ]
            body = [
                "contents": [
                    ["parts": [["text": "\(systemPrompt)\n\n\(userPrompt)"]]]
                ],
                "generationConfig": [
                    "maxOutputTokens": maxTokens
                ]
            ]

        case .ollama:
            url = URL(string: "\(endpoint)/api/chat")!
            headers = ["content-type": "application/json"]
            body = [
                "model": provider.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "stream": false
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        return try parseResponse(data: data, providerType: provider.type)
    }

    /// Parse the API response based on provider type.
    private func parseResponse(data: Data, providerType: AIProviderType) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        switch providerType {
        case .claude:
            if let content = json["content"] as? [[String: Any]],
               let first = content.first,
               let text = first["text"] as? String {
                return text
            }

        case .openAI, .openRouter, .copilot, .openCode, .custom:
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }

        case .gemini:
            if let candidates = json["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let firstPart = parts.first,
               let text = firstPart["text"] as? String {
                return text
            }

        case .ollama:
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        }

        throw AIError.invalidResponse
    }

    /// Streaming version of callAIProvider - updates streamingResponse incrementally.
    private func callAIProviderStreaming(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        let endpoint = provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        guard !endpoint.isEmpty else {
            throw AIError.invalidEndpoint
        }

        let url: URL
        let headers: [String: String]
        var body: [String: Any]

        switch provider.type {
        case .claude:
            url = URL(string: "\(endpoint)/v1/messages")!
            headers = [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json"
            ]
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "stream": true,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ]
            ]

        case .openAI, .openRouter, .copilot, .openCode, .custom:
            url = URL(string: "\(endpoint)/v1/chat/completions")!
            headers = [
                "Authorization": "Bearer \(apiKey)",
                "content-type": "application/json"
            ]
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "stream": true,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]

        case .ollama:
            url = URL(string: "\(endpoint)/api/chat")!
            headers = ["content-type": "application/json"]
            body = [
                "model": provider.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "stream": true
            ]

        case .gemini:
            // Gemini doesn't support streaming in the same way, use non-streaming
            return try await callAIProvider(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: maxTokens
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Use bytes for streaming
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errorBody = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Process streaming response
        var fullResponse = ""
        var buffer = ""

        for try await byte in bytes {
            guard !Task.isCancelled else { break }

            if let char = String(bytes: [byte], encoding: .utf8) {
                buffer += char

                // Process complete lines
                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                    buffer = String(buffer[newlineRange.upperBound...])

                    if line.hasPrefix("data: ") {
                        let jsonString = String(line.dropFirst(6))

                        if jsonString == "[DONE]" {
                            continue
                        }

                        if let data = jsonString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // OpenAI/Claude format
                            if let choices = json["choices"] as? [[String: Any]],
                               let first = choices.first,
                               let delta = first["delta"] as? [String: Any],
                               let content = delta["content"] as? String {
                                fullResponse += content
                                streamingResponse = fullResponse
                            }
                            // Claude format
                            else if let type = json["type"] as? String,
                                    type == "content_block_delta",
                                    let delta = json["delta"] as? [String: Any],
                                    let text = delta["text"] as? String {
                                fullResponse += text
                                streamingResponse = fullResponse
                            }
                            // Ollama format
                            else if let message = json["message"] as? [String: Any],
                                    let content = message["content"] as? String {
                                fullResponse += content
                                streamingResponse = fullResponse
                            } else {
                                // Log unrecognized stream events for debugging
                                Log.ai.debug("stream: unrecognized event=\(jsonString.prefix(200))")
                            }
                        }
                    }
                }
            }
        }

        return fullResponse
    }
}

/// Terminal context for AI queries.
struct TerminalContext {
    var currentDirectory: String?
    var shell: String?
    var recentCommands: [String]
    var terminalOutput: String?

    init(currentDirectory: String? = nil, shell: String? = nil, recentCommands: [String] = [], terminalOutput: String? = nil) {
        self.currentDirectory = currentDirectory
        self.shell = shell
        self.recentCommands = recentCommands
        self.terminalOutput = terminalOutput
    }
}

/// AI service errors.
enum AIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Invalid AI provider endpoint"
        case .invalidResponse:
            return "Invalid response from AI provider"
        case .apiError(let statusCode, let message):
            return "AI API error (\(statusCode)): \(message)"
        }
    }
}
