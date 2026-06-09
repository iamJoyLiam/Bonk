import Foundation

/// Builds and executes AI API requests for Agent mode.
enum AIRequestBuilder {
    struct RequestComponents {
        let url: URL
        let headers: [String: String]
        let body: [String: Any]
    }

    static func execute(
        provider: AIProviderConfig,
        endpoint: String,
        apiKey: String,
        messages: [[String: String]],
        maxTokens: Int
    ) async throws -> String {
        let components = try buildRequest(
            provider: provider,
            endpoint: endpoint,
            apiKey: apiKey,
            messages: messages,
            maxTokens: maxTokens
        )

        var request = URLRequest(url: components.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        components.headers.forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: components.body
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else
        {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw AIError.apiError(statusCode: code, message: body)
        }

        return try ResponseExtractor.extract(
            from: data,
            providerType: provider.type
        )
    }

    // MARK: - Build by Provider Type

    private static func buildRequest(
        provider: AIProviderConfig,
        endpoint: String,
        apiKey: String,
        messages: [[String: String]],
        maxTokens: Int
    ) throws -> RequestComponents {
        switch provider.type {
        case .claude:
            try buildClaude(
                endpoint: endpoint,
                apiKey: apiKey,
                model: provider.model,
                messages: messages,
                maxTokens: maxTokens
            )
        case .openAI, .openRouter, .openCode, .copilot, .custom:
            try buildOpenAI(
                endpoint: endpoint,
                apiKey: apiKey,
                model: provider.model,
                messages: messages,
                maxTokens: maxTokens
            )
        case .ollama:
            try buildOllama(
                endpoint: endpoint,
                model: provider.model,
                messages: messages
            )
        case .gemini:
            try buildGemini(
                endpoint: endpoint,
                apiKey: apiKey,
                model: provider.model,
                messages: messages,
                maxTokens: maxTokens
            )
        }
    }

    // MARK: - Claude

    private static func buildClaude(
        endpoint: String,
        apiKey: String,
        model: String,
        messages: [[String: String]],
        maxTokens: Int
    ) throws -> RequestComponents {
        guard let url = URL(
            string: "\(endpoint)/v1/messages"
        ) else {
            throw AIError.invalidEndpoint
        }

        let systemMsg = messages
            .first(where: { $0["role"] == "system" })?["content"] ?? ""
        let userMessages = messages.filter { $0["role"] != "system" }

        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemMsg,
            "messages": userMessages.map {
                [
                    "role": $0["role"] ?? "user",
                    "content": $0["content"] ?? "",
                ]
            },
        ]

        return RequestComponents(url: url, headers: headers, body: body)
    }

    // MARK: - OpenAI Compatible

    private static func buildOpenAI(
        endpoint: String,
        apiKey: String,
        model: String,
        messages: [[String: String]],
        maxTokens: Int
    ) throws -> RequestComponents {
        guard let url = URL(
            string: "\(endpoint)/v1/chat/completions"
        ) else {
            throw AIError.invalidEndpoint
        }

        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "content-type": "application/json",
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages.map {
                [
                    "role": $0["role"] ?? "user",
                    "content": $0["content"] ?? "",
                ]
            },
        ]

        return RequestComponents(url: url, headers: headers, body: body)
    }

    // MARK: - Ollama

    private static func buildOllama(
        endpoint: String,
        model: String,
        messages: [[String: String]]
    ) throws -> RequestComponents {
        guard let url = URL(
            string: "\(endpoint)/api/chat"
        ) else {
            throw AIError.invalidEndpoint
        }

        let headers = ["content-type": "application/json"]

        let body: [String: Any] = [
            "model": model,
            "messages": messages.map {
                [
                    "role": $0["role"] ?? "user",
                    "content": $0["content"] ?? "",
                ]
            },
            "stream": false,
        ]

        return RequestComponents(url: url, headers: headers, body: body)
    }

    // MARK: - Gemini

    private static func buildGemini(
        endpoint: String,
        apiKey: String,
        model: String,
        messages: [[String: String]],
        maxTokens: Int
    ) throws -> RequestComponents {
        guard let url = URL(
            string: "\(endpoint)/v1beta/models/\(model):generateContent"
        ) else {
            throw AIError.invalidEndpoint
        }

        let headers = [
            "x-goog-api-key": apiKey,
            "content-type": "application/json",
        ]

        let combined = messages.map {
            "\($0["role"] ?? "user"): \($0["content"] ?? "")"
        }.joined(separator: "\n\n")

        let body: [String: Any] = [
            "contents": [["parts": [["text": combined]]]],
            "generationConfig": ["maxOutputTokens": maxTokens],
        ]

        return RequestComponents(url: url, headers: headers, body: body)
    }
}

// MARK: - Response Extractor

enum ResponseExtractor {
    static func extract(
        from data: Data,
        providerType _: AIProviderType
    ) throws -> String {
        guard let json = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        // Claude: content[0].text
        if let content = json["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String
        {
            return text
        }
        // OpenAI: choices[0].message.content
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String
        {
            return text
        }
        // Ollama: message.content
        if let message = json["message"] as? [String: Any],
           let text = message["content"] as? String
        {
            return text
        }
        // Gemini: candidates[0].content.parts[0].text
        if let candidates = json["candidates"] as? [[String: Any]],
           let content = candidates.first?["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let text = parts.first?["text"] as? String
        {
            return text
        }

        throw AIError.invalidResponse
    }
}
