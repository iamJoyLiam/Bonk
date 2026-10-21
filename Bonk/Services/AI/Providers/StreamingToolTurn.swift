//
//  StreamingToolTurn.swift
//  Bonk
//
//  The streaming turn, for the two wire formats that can carry one.
//
//  A streaming turn is not a streaming answer: the model writes its text as
//  it goes *and* asks for commands to run, and both halves arrive
//  interleaved. A parser that only understood text would lose the tool
//  calls — and with them the whole agent loop.
//
//  Both implementations are the same shape:
///
///    1. build the request, with tools and `"stream": true`
///    2. read the SSE payloads
///    3. feed them to a pure accumulator
///    4. emit what the accumulator learned
//
//  The accumulators are the fiddly part and they are pure; these are the
//  transport.
//

import Foundation

// MARK: - OpenAI-compatible

extension OpenAICompatibleLLMProvider: LLMStreamingToolProvider {
    /// Stream a turn that may call tools.
    func streamTurn(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int?
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        messages: messages,
                        tools: tools,
                        stream: true,
                        maxTokens: maxTokens,
                        disableReasoning: false
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        let body = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        throw AIError.apiError(statusCode: http.statusCode, message: body)
                    }

                    var accumulator = OpenAIStreamAccumulator()
                    try await AIProviderNetworking.readSSEPayloads(bytes: bytes) { payload in
                        for event in accumulator.ingest(payload) {
                            continuation.yield(event)
                        }
                    }
                    for call in accumulator.toolCalls {
                        continuation.yield(.toolCall(call))
                    }
                    if let usage = accumulator.usage {
                        continuation.yield(.usage(usage))
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Anthropic

extension ClaudeLLMProvider: LLMStreamingToolProvider {
    /// Stream a turn that may call tools.
    ///
    /// The request is built by hand for the same reason the non-streaming
    /// tool turn is: the SDK's tool_use input type is a typed enum, and tool
    /// arguments are arbitrary JSON.
    func streamTurn(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int?
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resolvedMaxTokens = OutputTokenBudget.resolve(
                        perCall: maxTokens, saved: config.maxOutputTokens, providerType: config.type
                    )
                    let request = try makeStreamingToolRequest(
                        messages: messages,
                        tools: tools,
                        maxTokens: resolvedMaxTokens
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        let body = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        throw AIError.apiError(statusCode: http.statusCode, message: body)
                    }

                    var accumulator = AnthropicStreamAccumulator()
                    try await AIProviderNetworking.readSSEPayloads(bytes: bytes) { payload in
                        for event in accumulator.ingest(payload) {
                            continuation.yield(event)
                        }
                    }
                    for call in accumulator.toolCalls {
                        continuation.yield(.toolCall(call))
                    }
                    if let usage = accumulator.usage {
                        continuation.yield(.usage(usage))
                    }
                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The Anthropic Messages request for a streaming tool-enabled turn.
    private func makeStreamingToolRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int
    ) throws -> URLRequest {
        let endpoint = AIProviderNetworking.baseEndpoint(
            config.endpoint.isEmpty ? config.type.defaultEndpoint : config.endpoint
        )
        guard !endpoint.isEmpty,
              let url = URL(string: "\(endpoint)/v1/messages")
        else { throw AIError.invalidEndpoint }

        var body = AnthropicToolWire.requestBody(
            messages: messages,
            tools: tools,
            model: config.model,
            maxTokens: maxTokens
        )
        body["stream"] = true

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(
            AIProviderNetworking.anthropicVersion,
            forHTTPHeaderField: "anthropic-version"
        )
        for (key, value) in config.extraHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
