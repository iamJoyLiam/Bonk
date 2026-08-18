import Foundation

/// Provider adapter for OpenAI's Responses API (`/v1/responses`).
///
/// Implements the wire protocol directly (SSE included) so custom headers and
/// third-party servers that expose a Responses-compatible endpoint work the
/// same as OpenAI. Chat Completions stays the default path; this adapter is
/// only selected when the user opts in via the protocol switch.
final class OpenAIResponsesLLMProvider: LLMProvider, @unchecked Sendable {
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
        return try Self.parseResponse(from: data)
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

                    var pendingArguments: [String: String] = [:]
                    var emittedToolCallIDs = Set<String>()
                    var didEmitCompleted = false
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

                        try Self.parseStreamEvent(
                            object,
                            pendingArguments: &pendingArguments,
                            emittedToolCallIDs: &emittedToolCallIDs,
                            didEmitCompleted: &didEmitCompleted,
                            continuation: continuation
                        )
                    }

                    if !didEmitCompleted { continuation.yield(.completed) }
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
        return try Self.parseResponse(from: data)
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
              let url = URL(string: "\(endpoint)/v1/responses")
        else { throw AIError.invalidEndpoint }

        let systemPrompts = messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
        let input = messages
            .filter { $0.role != .system }
            .flatMap { message in
                message.responsesInputPayloads
            }

        var body: [String: Any] = [
            "model": config.model,
            "input": input,
            "max_output_tokens": maxTokens ?? config.maxOutputTokens ?? 500,
            "temperature": 0.0,
            "stream": stream,
        ]
        if !systemPrompts.isEmpty {
            body["instructions"] = systemPrompts.joined(separator: "\n\n")
        }
        if !tools.isEmpty {
            body["tools"] = tools.map(\.responsesPayload)
            body["tool_choice"] = "auto"
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

    // MARK: - Non-streaming Response Parsing

    private static func parseResponse(from data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String
        {
            throw AIError.apiError(statusCode: 0, message: message)
        }
        if let status = json["status"] as? String, status == "failed" {
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? "Responses API returned failed status"
            throw AIError.apiError(statusCode: 0, message: message)
        }

        var text = json["output_text"] as? String ?? ""
        var calls: [LLMToolCall] = []

        if let output = json["output"] as? [[String: Any]] {
            if text.isEmpty {
                text = Self.outputMessageText(from: output)
            }
            for item in output where (item["type"] as? String) == "function_call" {
                guard let callID = item["call_id"] as? String,
                      let name = item["name"] as? String
                else { continue }
                calls.append(LLMToolCall(
                    id: callID,
                    name: name,
                    argumentsJSON: item["arguments"] as? String ?? ""
                ))
            }
        }
        return LLMResponse(text: text, toolCalls: calls)
    }

    private static func outputMessageText(from output: [[String: Any]]) -> String {
        for item in output where (item["type"] as? String) == "output_message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where (part["type"] as? String) == "output_text" {
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    // MARK: - Streaming Event Parsing

    private static func parseStreamEvent(
        _ object: [String: Any],
        pendingArguments: inout [String: String],
        emittedToolCallIDs: inout Set<String>,
        didEmitCompleted: inout Bool,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) throws {
        guard let type = object["type"] as? String else { return }

        switch type {
        case "response.output_text.delta":
            if let delta = object["delta"] as? String {
                continuation.yield(.textDelta(delta))
            }

        case "response.reasoning_text.delta",
             "response.reasoning.delta",
             "response.reasoning_summary_text.delta":
            if let delta = object["delta"] as? String {
                continuation.yield(.reasoning(delta))
            }

        case "response.function_call_arguments.delta":
            if let itemID = object["item_id"] as? String,
               let delta = object["delta"] as? String
            {
                pendingArguments[itemID, default: ""] += delta
            }

        case "response.function_call_arguments.done":
            if let itemID = object["item_id"] as? String {
                if let arguments = object["arguments"] as? String {
                    pendingArguments[itemID] = arguments
                }
            }

        case "response.output_item.done":
            guard let item = object["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call",
                  let callID = item["call_id"] as? String,
                  !emittedToolCallIDs.contains(callID),
                  let name = item["name"] as? String
            else { return }
            emittedToolCallIDs.insert(callID)
            let itemID = item["id"] as? String ?? callID
            continuation.yield(.toolCall(LLMToolCall(
                id: callID,
                name: name,
                argumentsJSON: item["arguments"] as? String
                    ?? pendingArguments[itemID]
                    ?? ""
            )))

        case "response.completed":
            didEmitCompleted = true
            continuation.yield(.completed)

        case "response.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? "Responses API stream failed"
            throw AIError.apiError(statusCode: 0, message: message)

        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? "Responses API stream error"
            throw AIError.apiError(statusCode: 0, message: message)

        default:
            break
        }
    }
}

// MARK: - Wire conversion helpers

extension LLMMessage {
    var responsesInputPayloads: [[String: Any]] {
        switch role {
        case .tool:
            return [[
                "type": "function_call_output",
                "call_id": toolCallID ?? "",
                "output": content,
            ]]
        case .assistant:
            var payloads: [[String: Any]] = []
            if !content.isEmpty {
                payloads.append(["type": "message", "role": "assistant", "content": content])
            }
            for call in toolCalls ?? [] {
                payloads.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.name,
                    "arguments": call.argumentsJSON,
                ])
            }
            return payloads
        default:
            return [["type": "message", "role": role.rawValue, "content": content]]
        }
    }
}

extension LLMToolDefinition {
    var responsesPayload: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": parameters,
            "strict": false,
        ]
    }
}
