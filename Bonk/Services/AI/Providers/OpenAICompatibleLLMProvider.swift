import Foundation

/// Provider adapter for every OpenAI-compatible `/v1/chat/completions` server
/// (OpenAI, OpenRouter, OpenCode Zen, DeepSeek, Qwen, Kimi, custom, …).
/// Reuses the existing networking helpers as its transport, so the legacy
/// tolerant fallbacks and reasoning-disable payloads keep working.
final class OpenAICompatibleLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID: UUID
    let providerName: String
    let capability = LLMProviderCapability(supportsStreaming: true, supportsToolCalls: true)

    private let config: AIProviderConfig
    private let apiKey: String

    init(config: AIProviderConfig, apiKey: String) {
        providerID = config.id
        providerName = config.displayName
        self.config = config
        self.apiKey = apiKey
    }

    // MARK: - Chat

    func chat(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> LLMResponse {
        let request = try makeRequest(
            messages: messages,
            tools: [],
            stream: false,
            maxTokens: maxTokens,
            disableReasoning: disableReasoning
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfNeeded(response: response, data: data)
        let text = try AIProviderNetworking.extractResponse(from: data, type: config.type)
        return LLMResponse(text: text)
    }

    // MARK: - Stream

    func stream(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        messages: messages,
                        tools: [],
                        stream: true,
                        maxTokens: maxTokens,
                        disableReasoning: disableReasoning
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        let body = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        throw AIError.apiError(statusCode: http.statusCode, message: body)
                    }

                    var result = ""
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        guard byte == 0x0A, let line = String(data: buffer, encoding: .utf8) else { continue }
                        buffer = Data()
                        guard line.hasPrefix("data: ") else { continue }

                        let payload = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard payload != "[DONE]",
                              let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let text = AIProviderNetworking.extractDelta(from: object) {
                            result += text
                            continuation.yield(.textDelta(text))
                        }
                    }
                    if !result.isEmpty { continuation.yield(.completed) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Tool Calling

    func toolCall(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int?
    ) async throws -> LLMResponse {
        let resolvedMaxTokens = maxTokens ?? config.maxOutputTokens ?? 2000
        let request = try makeRequest(
            messages: messages,
            tools: tools,
            stream: false,
            maxTokens: resolvedMaxTokens,
            disableReasoning: false
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfNeeded(response: response, data: data)
        return try AIProviderNetworking.parseAgentTurn(from: data)
    }

    // MARK: - Discovery

    func listModels() async throws -> [String] {
        guard let url = AIProviderNetworking.modelsURL(endpoint: config.endpoint, type: config.type) else {
            throw AIError.invalidEndpoint
        }
        let request = AIProviderNetworking.makeRequest(
            url: url, apiKey: apiKey, type: config.type, extraHeaders: config.extraHeaders
        )
        return try await AIProviderNetworking.fetchModels(request: request, type: config.type)
    }

    func testConnection() async throws -> Bool {
        guard let url = AIProviderNetworking.modelsURL(endpoint: config.endpoint, type: config.type) else {
            throw AIError.invalidEndpoint
        }
        let request = AIProviderNetworking.makeRequest(
            url: url, apiKey: apiKey, type: config.type, extraHeaders: config.extraHeaders
        )
        return try await AIProviderNetworking.testConnection(request: request)
    }

    // MARK: - Request Building

    private func makeRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        stream: Bool,
        maxTokens: Int?,
        disableReasoning: Bool
    ) throws -> URLRequest {
        let endpoint = AIProviderNetworking.baseEndpoint(
            config.endpoint.isEmpty ? config.type.defaultEndpoint : config.endpoint
        )
        guard !endpoint.isEmpty,
              let url = URL(string: "\(endpoint)/v1/chat/completions")
        else { throw AIError.invalidEndpoint }

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens ?? config.maxOutputTokens ?? 500,
            "temperature": 0.0,
            "messages": messages.map(\.chatCompletionsPayload),
            "stream": stream,
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map(\.chatCompletionsPayload)
            body["tool_choice"] = "auto"
        }

        if disableReasoning,
           let reasoningPayload = AIProviderNetworking.reasoningDisablePayload(for: config.type)
        {
            body.merge(reasoningPayload) { $1 }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 60 : 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in config.extraHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func throwIfNeeded(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw AIError.apiError(statusCode: http.statusCode, message: preview)
        }
    }
}

// MARK: - Wire conversion helpers

extension LLMMessage {
    var chatCompletionsPayload: [String: Any] {
        var payload: [String: Any] = ["role": role.rawValue]

        switch role {
        case .tool:
            payload["content"] = content
            payload["tool_call_id"] = toolCallID ?? ""
        case .assistant where toolCalls?.isEmpty == false && content.isEmpty:
            payload["content"] = NSNull()
            if let toolCalls {
                payload["tool_calls"] = toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON,
                        ],
                    ]
                }
            }
        default:
            payload["content"] = content
            if let toolCalls, !toolCalls.isEmpty {
                payload["tool_calls"] = toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON,
                        ],
                    ]
                }
            }
        }
        return payload
    }
}

extension LLMToolDefinition {
    var chatCompletionsPayload: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }
}
