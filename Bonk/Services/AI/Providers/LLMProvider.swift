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

/// One model turn. `text` may be empty when the model only requested tools.
struct LLMResponse: Equatable, Sendable {
    let text: String
    let toolCalls: [LLMToolCall]

    init(text: String, toolCalls: [LLMToolCall] = []) {
        self.text = text
        self.toolCalls = toolCalls
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

/// What a provider can do. Agent Runtime uses this to decide between the
/// real tool loop and the legacy plan flow.
struct LLMProviderCapability: Equatable, Sendable {
    let supportsStreaming: Bool
    let supportsToolCalls: Bool
}

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
