import Foundation

/// Networking helpers for AI provider API interactions.
enum AIProviderNetworking {
    static let anthropicVersion = "2023-06-01"

    // MARK: - Build API Request

    static func makeRequest(
        url: URL,
        apiKey: String,
        type: AIProviderType,
        extraHeaders: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if type == .claude {
            // Claude uses the x-api-key header exclusively.
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        } else if type == .gemini {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        } else if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    // MARK: - Endpoint Normalization

    /// Normalize a provider endpoint to its base URL so appending
    /// `/v1/...` never produces double path segments. Strips trailing slashes,
    /// a trailing `/v1`, and pasted full chat-completions URLs like
    /// `http://host:4000/v1/chat/completions`.
    static func baseEndpoint(_ endpoint: String) -> String {
        var result = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        for suffix in ["/v1/responses", "/responses", "/v1/chat/completions", "/chat/completions", "/v1"] where result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        while result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        return result
    }

    // MARK: - Models URL

    static func modelsURL(endpoint: String, type: AIProviderType) -> URL? {
        let base = baseEndpoint(endpoint)
        guard let components = URLComponents(string: base) else { return nil }
        let basePath = components.path

        let suffix: String
        switch type {
        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .claude, .custom:
            suffix = "/v1/models"
        case .gemini:
            suffix = "/v1beta/models"
        case .ollama:
            suffix = "/api/tags"
        }

        // Append suffix to existing path (preserves /api for OpenRouter etc.)
        var newComponents = components
        newComponents.path = basePath + suffix
        return newComponents.url
    }

    // MARK: - Fetch Models

    static func fetchModels(request: URLRequest, type: AIProviderType) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        do {
            return try parseModels(from: data, type: type)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "non-utf8"
            throw URLError(.cannotParseResponse, userInfo: [
                NSLocalizedDescriptionKey: "Parse error: \(error.localizedDescription). Response: \(preview)",
            ])
        }
    }

    // MARK: - Test Connection

    static func testConnection(request: URLRequest) async throws -> Bool {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            return http.statusCode < 400
        }
        return false
    }

    // MARK: - Build Chat Request

    /// Build a provider-specific chat request (streaming or non-streaming).
    static func buildRequest( // swiftlint:disable:this function_body_length
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        stream: Bool,
        maxTokens: Int? = nil,
        disableReasoning: Bool = false
    ) throws -> URLRequest {
        let endpoint = baseEndpoint(
            provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        )
        guard !endpoint.isEmpty else { throw AIError.invalidEndpoint }

        let maxTokens = maxTokens ?? provider.maxOutputTokens ?? 500
        let capability = AIProviderCapabilityResolver.resolve(
            config: provider, workload: .chat
        ).capability
        let url: URL
        let headers: [String: String]
        let body: [String: Any]

        switch provider.type {
        case .claude:
            guard let endpointURL = URL(string: "\(endpoint)/v1/messages") else { throw AIError.invalidEndpoint }
            url = endpointURL
            headers = [
                "x-api-key": apiKey,
                "anthropic-version": anthropicVersion,
                "content-type": "application/json",
            ]
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "system": systemPrompt,
                "messages": [["role": "user", "content": userPrompt]],
            ].merging(stream ? ["stream": true] : [:]) { $1 }

        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .custom:
            // swiftlint:disable:next line_length
            guard let endpointURL = URL(string: "\(endpoint)/v1/chat/completions") else { throw AIError.invalidEndpoint }
            url = endpointURL
            headers = [
                "Authorization": "Bearer \(apiKey)",
                "content-type": "application/json",
            ]
            body = [
                "model": provider.model,
                "max_tokens": maxTokens,
                "temperature": 0.0,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt],
                ],
            ].merging(stream ? ["stream": true] : [:]) { $1 }
            // Inline completions must be fast — disable reasoning so the small
            // budget produces a suggestion instead of thinking tokens.
            .merging(
                disableReasoning
                    ? (reasoningDisablePayload(for: capability) ?? [:])
                    : [:]
            ) { $1 }

        case .gemini:
            let geminiPath = "\(endpoint)/v1beta/models/\(provider.model):generateContent"
            guard let endpointURL = URL(string: geminiPath) else { throw AIError.invalidEndpoint }
            url = endpointURL
            headers = [
                "x-goog-api-key": apiKey,
                "content-type": "application/json",
            ]
            body = [
                "contents": [["parts": [["text": "\(systemPrompt)\n\n\(userPrompt)"]]]],
                "generationConfig": ["maxOutputTokens": maxTokens],
            ]

        case .ollama:
            guard let endpointURL = URL(string: "\(endpoint)/api/chat") else { throw AIError.invalidEndpoint }
            url = endpointURL
            headers = ["content-type": "application/json"]
            body = [
                "model": provider.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt],
                ],
                "stream": stream,
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 60 : 30
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        for (key, value) in provider.extraHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response Extraction

    /// Extract the response text from a non-streaming API response.
    static func extractResponse(from data: Data, type _: AIProviderType) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        // Claude: content[0].text
        if let content = json["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String
        { return text }

        // OpenAI: choices[0].message.content
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String
        { return text }

        // Ollama: message.content
        if let message = json["message"] as? [String: Any],
           let text = message["content"] as? String
        { return text }

        // Gemini: candidates[0].content.parts[0].text
        if let candidates = json["candidates"] as? [[String: Any]],
           let content = candidates.first?["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let text = parts.first?["text"] as? String
        { return text }

        throw AIError.invalidResponse
    }

    // MARK: - Streaming Request

    /// Execute a streaming request and return the accumulated response.
    /// Claude streams via SwiftAnthropic; OpenAI-compatible providers use the
    /// tolerant SSE parser; Gemini is non-streaming; Ollama falls back.
    static func streamRequest(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int? = nil,
        disableReasoning: Bool = false,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> String {
        switch provider.type {
        case .gemini:
            return try await nonStreamRequest(
                provider: provider, apiKey: apiKey,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                maxTokens: maxTokens
            )
        case .claude:
            return try await claudeStream(
                provider: provider, apiKey: apiKey,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                maxTokens: maxTokens, onDelta: onDelta
            )
        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .custom:
            return try await legacyStream(
                provider: provider, apiKey: apiKey,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                maxTokens: maxTokens, disableReasoning: disableReasoning, onDelta: onDelta
            )
        case .ollama:
            do {
                return try await openAIStream(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    maxTokens: maxTokens, onDelta: onDelta
                )
            } catch {
                // Older Ollama builds lack /v1/chat/completions; use native /api/chat.
                guard shouldFallbackToLegacy(error) else { throw error }
                return try await legacyStream(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    maxTokens: maxTokens, disableReasoning: disableReasoning, onDelta: onDelta
                )
            }
        }
    }

    // MARK: - Non-Streaming Request

    /// Execute a non-streaming request (used as Gemini fallback and for agent mode).
    static func nonStreamRequest(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int? = nil,
        disableReasoning: Bool = false
    ) async throws -> String {
        switch provider.type {
        case .claude:
            return try await claudeNonStream(
                provider: provider, apiKey: apiKey,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                maxTokens: maxTokens
            )
        case .openAI, .openRouter, .openCode, .deepSeek, .qwen, .kimi, .custom:
            do {
                return try await openAINonStream(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    maxTokens: maxTokens
                )
            } catch {
                // Fall back to the tolerant hand-built parser if the SDK's
                // strict decode rejects the provider's response shape.
                guard shouldFallbackToLegacy(error) else { throw error }
                return try await legacyNonStream(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    maxTokens: maxTokens, disableReasoning: disableReasoning
                )
            }
        case .ollama:
            do {
                return try await openAINonStream(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    maxTokens: maxTokens
                )
            } catch {
                guard shouldFallbackToLegacy(error) else { throw error }
                return try await legacyNonStream(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: systemPrompt, userPrompt: userPrompt,
                    maxTokens: maxTokens, disableReasoning: disableReasoning
                )
            }
        case .gemini:
            return try await legacyNonStream(
                provider: provider, apiKey: apiKey,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                maxTokens: maxTokens, disableReasoning: disableReasoning
            )
        }
    }

    // MARK: - Parse Models

    private static func parseModels(from data: Data, type: AIProviderType) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // OpenAI / OpenRouter / OpenCode / Claude: { "data": [{ "id": "..." }] }
        if let data = json?["data"] as? [[String: Any]] {
            return data.compactMap { $0["id"] as? String }.sorted()
        }

        // Ollama / Gemini: { "models": [{ "name": "..." }] }
        if let models = json?["models"] as? [[String: Any]] {
            return models.compactMap { item -> String? in
                guard let name = item["name"] as? String else { return nil }
                // Gemini names are prefixed with "models/"
                if type == .gemini {
                    return name.replacingOccurrences(of: "models/", with: "")
                }
                return name
            }.sorted()
        }

        return []
    }
}
