//
//  AgentModelGateway.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation

/// Protocol abstracting model communication and tool-calling serialization.
protocol AgentModelGateway: Sendable {
    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse

    /// Stream the turn, when the provider can.
    ///
    /// A streaming turn has to carry tool calls as well as text: the model
    /// writes its answer as it goes *and* asks for commands to run, and both
    /// halves arrive interleaved. A provider whose wire format cannot do
    /// that answers nil, and the runtime falls back to a non-streaming turn
    /// — the run behaves the same, it just does not stream.
    func streamTurn(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>?
}

/// Concrete adapter for any existing LLMProvider instance.
struct LLMProviderModelGateway: AgentModelGateway {
    let provider: any LLMProvider

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
        let turn = try await provider.toolCall(
            messages: messages,
            tools: tools,
            maxTokens: nil
        )
        let toolCalls = turn.toolCalls.map {
            LLMToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON)
        }
        return LLMResponse(text: turn.text, toolCalls: toolCalls, usage: turn.usage)
    }

    func streamTurn(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
        guard let streaming = provider as? any LLMStreamingToolProvider else { return nil }
        return streaming.streamTurn(messages: messages, tools: tools, maxTokens: nil)
    }
}
