import Foundation
import os.log
import SwiftUI

/// AI service that provides terminal assistance features.
@Observable @MainActor
final class AIService {
    static let shared = AIService()

    var currentExplanation: String?
    var isProcessing = false
    var lastError: String?
    var streamingResponse: String = ""

    // MARK: - Public API

    func chat(_ message: String, context _: TerminalContext) async {
        let systemPrompt = """
        You are a terminal assistant embedded in an SSH client.
        Answer concisely in plain text. If providing a command, show it on its own line.
        No greetings or filler. Match the user's language.
        """
        await execute(systemPrompt: systemPrompt, userPrompt: message, label: "chat")
    }

    func explainError(_ errorOutput: String, context _: TerminalContext) async {
        let systemPrompt = """
        You are a terminal error diagnoser embedded in an SSH client.
        Explain the error briefly and suggest a fix. Reply in plain text, no markdown.
        Match the user's language.
        """
        await execute(systemPrompt: systemPrompt, userPrompt: "Explain this terminal error:\n\n\(errorOutput)", label: "explainError")
    }

    // MARK: - Core

    private func execute(systemPrompt: String, userPrompt: String, label: String) async {
        guard let (provider, apiKey) = resolveProvider() else { return }

        let modelLower = provider.model.lowercased()
        if modelLower.contains("safety") || modelLower.contains("classifier") {
            lastError = "Model '\(provider.model)' is a safety classifier, not a chat model. Change it in Settings → AI."
            Log.ai.error("\(label): safety classifier detected: \(provider.model)")
            return
        }

        isProcessing = true
        streamingResponse = ""
        defer { isProcessing = false }

        Log.ai.info("\(label): provider=\(provider.name) model=\(provider.model) msg=\(userPrompt.prefix(80))")

        do {
            let response = try await streamRequest(provider: provider, apiKey: apiKey, systemPrompt: systemPrompt, userPrompt: userPrompt)
            Log.ai.info("\(label): response(\(response.count) chars)=\(response.prefix(200))")
            if !Task.isCancelled { currentExplanation = response }
        } catch {
            lastError = error.localizedDescription
            Log.ai.error("\(label): error=\(error.localizedDescription)")
        }
    }

    /// Resolve active provider and validate API key.
    private func resolveProvider() -> (AIProviderConfig, String)? {
        guard let provider = AIProviderStore.activeProvider else {
            lastError = "No active AI provider configured"
            return nil
        }
        let key = provider.apiKey
        guard !key.isEmpty else {
            lastError = "API key not set for \(provider.name)"
            return nil
        }
        return (provider, key)
    }

    // MARK: - Request Building

    private static let anthropicVersion = "2023-06-01"

    /// Build URL, headers, and body for a provider API call.
    private func buildRequest(provider: AIProviderConfig, apiKey: String, systemPrompt: String, userPrompt: String, stream: Bool) throws -> URLRequest {
        let endpoint = provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        guard !endpoint.isEmpty else { throw AIError.invalidEndpoint }

        let maxTokens = provider.maxOutputTokens ?? 500
        let url: URL
        let headers: [String: String]
        let body: [String: Any]

        switch provider.type {
        case .claude:
            guard let u = URL(string: "\(endpoint)/v1/messages") else { throw AIError.invalidEndpoint }
            url = u
            headers = ["x-api-key": apiKey, "anthropic-version": Self.anthropicVersion, "content-type": "application/json"]
            body = [
                "model": provider.model, "max_tokens": maxTokens, "system": systemPrompt,
                "messages": [["role": "user", "content": userPrompt]]
            ].merging(stream ? ["stream": true] : [:]) { $1 }

        case .openAI, .openRouter, .copilot, .openCode, .custom:
            guard let u = URL(string: "\(endpoint)/v1/chat/completions") else { throw AIError.invalidEndpoint }
            url = u
            headers = ["Authorization": "Bearer \(apiKey)", "content-type": "application/json"]
            body = [
                "model": provider.model, "max_tokens": maxTokens,
                "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": userPrompt]]
            ].merging(stream ? ["stream": true] : [:]) { $1 }

        case .gemini:
            guard let u = URL(string: "\(endpoint)/v1beta/models/\(provider.model):generateContent") else { throw AIError.invalidEndpoint }
            url = u
            headers = ["x-goog-api-key": apiKey, "content-type": "application/json"]
            body = [
                "contents": [["parts": [["text": "\(systemPrompt)\n\n\(userPrompt)"]]]],
                "generationConfig": ["maxOutputTokens": maxTokens]
            ]

        case .ollama:
            guard let u = URL(string: "\(endpoint)/api/chat") else { throw AIError.invalidEndpoint }
            url = u
            headers = ["content-type": "application/json"]
            body = [
                "model": provider.model,
                "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": userPrompt]],
                "stream": stream
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 60 : 30
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Streaming

    private func streamRequest(provider: AIProviderConfig, apiKey: String, systemPrompt: String, userPrompt: String) async throws -> String {
        // Gemini doesn't support SSE streaming
        if provider.type == .gemini {
            return try await simpleRequest(provider: provider, apiKey: apiKey, systemPrompt: systemPrompt, userPrompt: userPrompt)
        }

        let request = try buildRequest(provider: provider, apiKey: apiKey, systemPrompt: systemPrompt, userPrompt: userPrompt, stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            throw AIError.apiError(statusCode: http.statusCode, message: String(data: errorData, encoding: .utf8) ?? "Unknown error")
        }

        return try await parseStream(bytes: bytes, providerType: provider.type)
    }

    private func parseStream(bytes: URLSession.AsyncBytes, providerType: AIProviderType) async throws -> String {
        var result = ""
        var buffer = ""

        for try await byte in bytes {
            guard !Task.isCancelled else { break }
            guard let char = String(bytes: [byte], encoding: .utf8) else { continue }
            buffer += char

            while let range = buffer.range(of: "\n") {
                let line = String(buffer[buffer.startIndex ..< range.lowerBound])
                buffer = String(buffer[range.upperBound...])

                guard line.hasPrefix("data: ") else { continue }
                let json = String(line.dropFirst(6))
                guard json != "[DONE]", let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                if let text = extractDelta(from: obj, type: providerType) {
                    result += text
                    streamingResponse = result
                }
            }
        }
        return result
    }

    /// Extract incremental text from a streaming event.
    private func extractDelta(from json: [String: Any], type _: AIProviderType) -> String? {
        // OpenAI format: choices[0].delta.content
        if let choices = json["choices"] as? [[String: Any]],
           let content = choices.first?["delta"] as? [String: Any],
           let text = content["content"] as? String { return text }
        // Claude format: type == "content_block_delta"
        if json["type"] as? String == "content_block_delta",
           let text = (json["delta"] as? [String: Any])?["text"] as? String { return text }
        // Ollama format: message.content
        if let text = (json["message"] as? [String: Any])?["content"] as? String { return text }
        return nil
    }

    // MARK: - Non-Streaming (Gemini fallback)

    private func simpleRequest(provider: AIProviderConfig, apiKey: String, systemPrompt: String, userPrompt: String) async throws -> String {
        let request = try buildRequest(provider: provider, apiKey: apiKey, systemPrompt: systemPrompt, userPrompt: userPrompt, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.apiError(statusCode: code, message: String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        // Gemini: candidates[0].content.parts[0].text
        if let text = (json["candidates"] as? [[String: Any]])?.first
            .flatMap({ $0["content"] as? [String: Any] })
            .flatMap({ $0["parts"] as? [[String: Any]] })
            .flatMap(\.first)
            .flatMap({ $0["text"] as? String }) { return text }
        // OpenAI: choices[0].message.content
        if let text = (json["choices"] as? [[String: Any]])?.first
            .flatMap({ $0["message"] as? [String: Any] })
            .flatMap({ $0["content"] as? String }) { return text }
        // Claude: content[0].text
        if let text = (json["content"] as? [[String: Any]])?.first
            .flatMap({ $0["text"] as? String }) { return text }
        // Ollama: message.content
        if let text = (json["message"] as? [String: Any])
            .flatMap({ $0["content"] as? String }) { return text }

        throw AIError.invalidResponse
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
}
