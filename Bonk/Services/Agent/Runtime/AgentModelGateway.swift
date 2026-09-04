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
    func stream(messages: [LLMMessage]) -> AsyncThrowingStream<LLMStreamEvent, Error>
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
        return LLMResponse(text: turn.text, toolCalls: toolCalls)
    }

    func stream(messages: [LLMMessage]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        provider.stream(
            messages: messages,
            maxTokens: nil,
            disableReasoning: false
        )
    }
}
