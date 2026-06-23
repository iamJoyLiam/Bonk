import Foundation

/// Networking helpers for AI provider API interactions.
enum AIProviderNetworking {
    private static let anthropicVersion = "2023-06-01"

    // MARK: - Build API Request

    static func makeRequest(url: URL, apiKey: String, type: AIProviderType) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if type.needsAPIKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if type == .claude {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        if type == .gemini {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }

    // MARK: - Endpoint Normalization

    /// Strip trailing `/v1` (or `/v1/`) from an endpoint to avoid double path segments.
    /// Users often enter `https://api.example.com/v1` as the endpoint, but the code
    /// appends `/v1/models` or `/v1/chat/completions`, producing `/v1/v1/...`.
    static func baseEndpoint(_ endpoint: String) -> String {
        var result = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        if result.hasSuffix("/v1") { result = String(result.dropLast(3)) }
        return result
    }

    // MARK: - Models URL

    static func modelsURL(endpoint: String, type: AIProviderType, apiKey _: String) -> URL? {
        let base = baseEndpoint(endpoint)
        guard let components = URLComponents(string: base) else { return nil }
        let basePath = components.path

        let suffix: String
        switch type {
        case .openAI, .openRouter, .openCode, .claude, .custom:
            suffix = "/v1/models"
        case .gemini:
            suffix = "/v1beta/models"
        case .ollama:
            suffix = "/api/tags"
        case .copilot:
            return nil
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
        stream: Bool
    ) throws -> URLRequest {
        let endpoint = baseEndpoint(
            provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        )
        guard !endpoint.isEmpty else { throw AIError.invalidEndpoint }

        let maxTokens = provider.maxOutputTokens ?? 500
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

        case .openAI, .openRouter, .copilot, .openCode, .custom:
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

    /// Extract incremental text from a streaming SSE event.
    static func extractDelta(from json: [String: Any]) -> String? {
        // OpenAI: choices[0].delta.content
        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let text = delta["content"] as? String
        { return text }

        // Claude: type == "content_block_delta"
        if json["type"] as? String == "content_block_delta",
           let delta = json["delta"] as? [String: Any],
           let text = delta["text"] as? String
        { return text }

        // Ollama: message.content
        if let message = json["message"] as? [String: Any],
           let text = message["content"] as? String
        { return text }

        return nil
    }

    // MARK: - Streaming Request

    /// Execute a streaming request and return the accumulated response.
    /// Falls back to non-streaming for Gemini.
    static func streamRequest(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> String {
        if provider.type == .gemini {
            return try await nonStreamRequest(
                provider: provider, apiKey: apiKey,
                systemPrompt: systemPrompt, userPrompt: userPrompt
            )
        }

        let request = try buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt, stream: true
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let body = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: http.statusCode, message: body)
        }

        return try await parseStream(bytes: bytes, providerType: provider.type, onDelta: onDelta)
    }

    // MARK: - Non-Streaming Request

    /// Execute a non-streaming request (used as Gemini fallback).
    static func nonStreamRequest(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let request = try buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt, stream: false
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: code, message: body)
        }

        return try extractResponse(from: data, type: provider.type)
    }

    // MARK: - Stream Parsing

    /// Parse an SSE stream and return the accumulated response text.
    /// Calls `onDelta` for each incremental chunk (caller controls UI cadence).
    static func parseStream(
        bytes: URLSession.AsyncBytes,
        providerType _: AIProviderType,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> String {
        var result = ""
        var buffer = ""

        for try await byte in bytes {
            guard let char = String(bytes: [byte], encoding: .utf8) else { continue }
            buffer += char

            while let range = buffer.range(of: "\n") {
                let line = String(buffer[buffer.startIndex ..< range.lowerBound])
                buffer = String(buffer[range.upperBound...])

                guard line.hasPrefix("data: ") else { continue }
                let json = String(line.dropFirst(6))
                guard json != "[DONE]",
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                if let text = extractDelta(from: obj) {
                    result += text
                    onDelta?(text)
                }
            }
        }
        return result
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

// MARK: - String Helper

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
