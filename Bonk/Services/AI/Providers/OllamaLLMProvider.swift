import Foundation

/// Ollama adapter. Newer Ollama builds expose `/v1/chat/completions`; older
/// ones only speak native `/api/chat`. This adapter keeps the existing
/// try-OpenAI-then-fallback behavior.
final class OllamaLLMProvider: LLMProvider, @unchecked Sendable {
    let providerID: UUID
    let providerName: String
    let capability = LLMProviderCapability(supportsStreaming: true, supportsToolCalls: false)

    private let config: AIProviderConfig
    private let apiKey: String

    init(config: AIProviderConfig, apiKey: String) {
        providerID = config.id
        providerName = config.displayName
        self.config = config
        self.apiKey = apiKey
    }

    func chat(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> LLMResponse {
        let pair = try Self.systemUserPair(messages)
        let text = try await AIProviderNetworking.nonStreamRequest(
            provider: config,
            apiKey: apiKey,
            systemPrompt: pair.system,
            userPrompt: pair.user,
            maxTokens: maxTokens,
            disableReasoning: disableReasoning
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
                    let text = try await AIProviderNetworking.streamRequest(
                        provider: config,
                        apiKey: apiKey,
                        systemPrompt: pair.system,
                        userPrompt: pair.user,
                        maxTokens: maxTokens,
                        disableReasoning: disableReasoning
                    ) { delta in
                        continuation.yield(.textDelta(delta))
                    }
                    if !text.isEmpty { continuation.yield(.completed) }
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
        throw AIError.unsupported("Ollama tool loop is not enabled yet")
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
