import Foundation

extension AIProviderNetworking {
    // MARK: - Agent Tool Loop

    /// One raw chat-completions round-trip with function-calling tools
    /// (OpenAI-compatible providers only). Returns the model's text plus any
    /// tool calls it requested; the caller executes tools and loops back.
    static func agentChat(
        provider: AIProviderConfig,
        apiKey: String,
        messages: [[String: Any]],
        tools: [[String: Any]]
    ) async throws -> AgentChatTurn {
        let endpoint = baseEndpoint(
            provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        )
        guard !endpoint.isEmpty,
              let url = URL(string: "\(endpoint)/v1/chat/completions")
        else { throw AIError.invalidEndpoint }

        let body: [String: Any] = [
            "model": provider.model,
            "max_tokens": provider.maxOutputTokens ?? 2000,
            "temperature": 0.0,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (key, value) in provider.extraHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw AIError.apiError(statusCode: http.statusCode, message: preview)
        }

        return try parseAgentTurn(from: data)
    }

    /// Parse a chat-completions payload into text + tool calls.
    /// Pure function so it is unit-testable.
    static func parseAgentTurn(from data: Data) throws -> AgentChatTurn {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else {
            throw AIError.invalidResponse
        }

        let content = message["content"] as? String
        var calls: [AgentToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                guard let id = raw["id"] as? String,
                      let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }
                let argsString = function["arguments"] as? String ?? ""
                calls.append(LLMToolCall(id: id, name: name, argumentsJSON: argsString))
            }
        }
        return LLMResponse(text: content ?? "", toolCalls: calls)
    }
}
