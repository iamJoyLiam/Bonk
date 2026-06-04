//
//  AIService.swift
//  GhostShell
//
//  AI service layer that connects AI providers to terminal features.
//

import Foundation
import SwiftUI

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
            return
        }

        let apiKey = provider.apiKey
        guard !apiKey.isEmpty else {
            lastError = "API key not set for \(provider.name)"
            return
        }

        isProcessing = true
        streamingResponse = ""
        defer { isProcessing = false }

        let systemPrompt = """
        You are a helpful terminal assistant. Answer the user's question concisely and accurately.
        If they ask about a command, provide the command and brief explanation.
        Keep responses short and practical.
        """

        do {
            let response = try await callAIProviderStreaming(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userPrompt: message,
                maxTokens: 500
            )

            if !Task.isCancelled {
                currentExplanation = response
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Explain an error from terminal output.
    func explainError(_ errorOutput: String, context: TerminalContext) async {
        guard let provider = activeProvider else {
            lastError = "No active AI provider configured"
            return
        }

        let apiKey = provider.apiKey
        guard !apiKey.isEmpty else {
            lastError = "API key not set for \(provider.name)"
            return
        }

        isProcessing = true
        streamingResponse = ""
        defer { isProcessing = false }

        let systemPrompt = """
        You are a terminal error explainer. Analyze the error output and provide a clear, concise explanation.
        Include:
        1. What the error means
        2. Likely cause
        3. Suggested fix

        Keep the explanation brief and actionable.
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
                "messages": [
                    ["role": "user", "content": "\(systemPrompt)\n\n\(userPrompt)"]
                ]
            ]

        case .openAI, .openRouter, .copilot:
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

        case .openCode, .custom:
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
                "messages": [
                    ["role": "user", "content": "\(systemPrompt)\n\n\(userPrompt)"]
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
