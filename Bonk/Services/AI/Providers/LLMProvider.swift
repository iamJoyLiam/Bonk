import Foundation

/// Which OpenAI-style wire protocol a provider speaks.
/// OpenAI defaults to Responses; third-party servers default to Chat
/// Completions for proxy compatibility, with Responses as an opt-in for
/// servers that implement `/v1/responses`.
enum AIProviderProtocol: String, CaseIterable, Identifiable, Codable, Sendable {
    case chatCompletions
    case responses

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatCompletions: I18n.shared.t(.chatCompletions)
        case .responses: I18n.shared.t(.responsesAPI)
        }
    }
}

/// One message in a provider-agnostic conversation.
struct LLMMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    let role: Role
    let content: String
    let toolCallID: String?
    let toolCalls: [LLMToolCall]?

    init(
        role: Role,
        content: String = "",
        toolCallID: String? = nil,
        toolCalls: [LLMToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    static func system(_ text: String) -> LLMMessage {
        .init(role: .system, content: text)
    }

    static func user(_ text: String) -> LLMMessage {
        .init(role: .user, content: text)
    }
}

/// A function call requested by the model.
struct LLMToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

/// Normalized token usage from any provider. All fields optional: a nil
/// struct (or nil field) means "provider did not report", never zero.
/// Budget enforcement must only use reported values; estimates live in
/// TokenEstimator and are explicitly labeled, never stored here.
struct TokenUsage: Equatable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    /// True when at least one field was reported.
    var isReported: Bool {
        inputTokens != nil || outputTokens != nil || totalTokens != nil
    }

    /// Chat Completions wire shape: {prompt_tokens, completion_tokens, total_tokens}.
    static func chatCompletions(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let parsed = TokenUsage(
            inputTokens: usage["prompt_tokens"] as? Int,
            outputTokens: usage["completion_tokens"] as? Int,
            totalTokens: usage["total_tokens"] as? Int
        )
        return parsed.isReported ? parsed : nil
    }

    /// Responses API wire shape: {input_tokens, output_tokens, total_tokens}.
    static func responsesAPI(from json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let parsed = TokenUsage(
            inputTokens: usage["input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            totalTokens: usage["total_tokens"] as? Int
        )
        return parsed.isReported ? parsed : nil
    }
}

/// One model turn. `text` may be empty when the model only requested tools.
/// `usage` carries reported token counts (nil = provider did not report).
struct LLMResponse: Equatable, Sendable {
    let text: String
    let toolCalls: [LLMToolCall]
    let usage: TokenUsage?

    init(text: String, toolCalls: [LLMToolCall] = [], usage: TokenUsage? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
    }

    /// Keeps the old `AgentChatTurn` spelling for callers that treat an empty
    /// response as "no content".
    var content: String? {
        text.isEmpty ? nil : text
    }
}

/// Unified streaming event model. Adapters translate each vendor's wire
/// format into these events; consumers never see protocol-specific shapes.
enum LLMStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case reasoning(String)
    case toolCall(LLMToolCall)
    case completed
}

/// A function definition the runtime can offer to any provider.
struct LLMToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    let parametersJSON: String

    init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    var parameters: [String: Any] {
        guard let data = parametersJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

/// Backward-compatible name used by Agent Runtime. Capability is now model
/// scoped and resolved by AIProviderCapabilityResolver.
typealias LLMProviderCapability = ModelCapability

/// Standard LLM provider abstraction. Business code talks to this protocol;
/// each adapter owns SDK/HTTP/SSE specifics.
protocol LLMProvider: Sendable {
    var providerID: UUID { get }
    var providerName: String { get }
    var capability: LLMProviderCapability { get }

    func chat(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> LLMResponse

    func stream(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>

    func toolCall(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int?
    ) async throws -> LLMResponse

    func listModels() async throws -> [String]
    func testConnection() async throws -> Bool
}

// Backward-compatible spellings used by AgentEngine/AgentToolExecutor and tests.
typealias AgentChatTurn = LLMResponse
typealias AgentToolCall = LLMToolCall
