import Foundation

/// Claude adapter. SwiftAnthropic stays inside this class; Agent Runtime only
/// sees the unified `LLMProvider` surface.
final class ClaudeLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID: UUID
    let providerName: String
    let capability: LLMProviderCapability

    private let config: AIProviderConfig
    private let apiKey: String
    /// The session the tool loop posts through. Injectable so the request
    /// can be exercised without a network; production uses the shared one.
    private let session: URLSession

    init(
        config: AIProviderConfig,
        apiKey: String,
        capability: LLMProviderCapability? = nil,
        session: URLSession = .shared
    ) {
        providerID = config.id
        providerName = config.displayName
        self.capability = capability ?? LLMProviderCapability(
            supportsStreaming: true, supportsToolCalls: true
        )
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    func chat(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> LLMResponse {
        let pair = try Self.systemUserPair(messages)
        let text = try await AIProviderNetworking.claudeNonStream(
            provider: config,
            apiKey: apiKey,
            systemPrompt: pair.system,
            userPrompt: pair.user,
            maxTokens: maxTokens
        )
        return LLMResponse(text: text)
    }

    func stream(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let pair = try Self.systemUserPair(messages)
                    var result = ""
                    let text = try await AIProviderNetworking.claudeStream(
                        provider: config,
                        apiKey: apiKey,
                        systemPrompt: pair.system,
                        userPrompt: pair.user,
                        maxTokens: maxTokens
                    ) { delta in
                        result += delta
                        continuation.yield(.textDelta(delta))
                    }
                    if !text.isEmpty || !result.isEmpty { continuation.yield(.completed) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func toolCall(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int?
    ) async throws -> LLMResponse {
        let resolvedMaxTokens = OutputTokenBudget.resolve(
            perCall: maxTokens, saved: config.maxOutputTokens, providerType: config.type
        )
        let request = try makeToolRequest(
            messages: messages,
            tools: tools,
            maxTokens: resolvedMaxTokens
        )
        let (data, response) = try await session.data(for: request)
        try Self.throwIfNeeded(response: response, data: data)
        return try AnthropicToolWire.parseResponse(data)
    }

    // MARK: - Request Building

    /// The Anthropic Messages request for a tool-enabled turn.
    ///
    /// Built by hand rather than through SwiftAnthropic: the SDK's tool_use
    /// input type is a typed enum, and tool arguments are arbitrary JSON.
    /// The plain chat and streaming paths still use the SDK.
    private func makeToolRequest(
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A tool loop turn is a full model turn, not a quick completion.
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
        request.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicToolWire.requestBody(
                messages: messages,
                tools: tools,
                model: config.model,
                maxTokens: maxTokens
            )
        )
        return request
    }

    private static func throwIfNeeded(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw AIError.apiError(statusCode: http.statusCode, message: preview)
        }
    }

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

    private static func systemUserPair(_ messages: [LLMMessage]) throws -> (system: String, user: String) {
        let system = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        guard let user = messages.last(where: { $0.role == .user })?.content else {
            throw AIError.invalidResponse
        }
        return (system, user)
    }
}
