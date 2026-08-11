//
//  AIProviderNetworking+SDK.swift
//  Bonk
//
//  SDK-backed request paths: OpenAI-compatible providers via the MacPaw/OpenAI
//  package, Claude via SwiftAnthropic, plus the legacy URLSession fallbacks
//  (Gemini and Ollama's native /api/chat).
//

import Foundation
import OpenAI
import SwiftAnthropic

extension AIProviderNetworking {

    // MARK: - SDK Clients

    /// Builds a MacPaw/OpenAI client for any OpenAI-compatible endpoint.
    /// Preserves path prefixes (e.g. OpenRouter `/api`, custom `/v1` bases).
    static func openAIClient(provider: AIProviderConfig, apiKey: String) -> OpenAI? {
        let endpoint = baseEndpoint(
            provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        )
        guard !endpoint.isEmpty, let url = URL(string: endpoint), let host = url.host else {
            return nil
        }
        let scheme = url.scheme ?? "https"
        let port = url.port ?? (scheme == "http" ? 80 : 443)
        // SDK appends `/chat/completions`; mimic the legacy `baseEndpoint + /v1` layout.
        let basePath = url.path.isEmpty ? "/v1" : url.path + "/v1"
        return OpenAI(configuration: .init(
            token: provider.type.needsAPIKey ? apiKey : nil,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: 60
        ))
    }

    /// Builds a SwiftAnthropic client pointed at the provider's endpoint.
    static func anthropicService(provider: AIProviderConfig, apiKey: String) -> AnthropicService {
        let endpoint = baseEndpoint(
            provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
        )
        let base = endpoint.isEmpty ? "https://api.anthropic.com" : endpoint
        return AnthropicServiceFactory.service(
            apiKey: apiKey,
            apiVersion: anthropicVersion,
            basePath: base,
            betaHeaders: nil
        )
    }

    /// Chat query for OpenAI-compatible providers.
    /// Uses the legacy `max_tokens` field so older servers (OpenRouter, DeepSeek,
    /// self-hosted OpenAI-compatible endpoints) keep working.
    static func openAIChatQuery(
        provider: AIProviderConfig,
        systemPrompt: String,
        userPrompt: String,
        stream: Bool,
        maxTokens: Int?
    ) -> ChatQuery {
        var query = ChatQuery(
            messages: [
                ChatQuery.ChatCompletionMessageParam(role: .system, content: systemPrompt)
                    ?? .system(.init(content: .textContent(systemPrompt))),
                ChatQuery.ChatCompletionMessageParam(role: .user, content: userPrompt)
                    ?? .user(.init(content: .string(userPrompt))),
            ],
            model: provider.model,
            temperature: 0.0,
            stream: stream
        )
        query.maxTokens = maxTokens ?? provider.maxOutputTokens ?? 500
        return query
    }

    /// Message parameter for Claude via SwiftAnthropic.
    static func claudeMessageParameter(
        provider: AIProviderConfig,
        systemPrompt: String,
        userPrompt: String,
        stream: Bool,
        maxTokens: Int?
    ) -> MessageParameter {
        MessageParameter(
            model: .other(provider.model),
            messages: [.init(role: .user, content: .text(userPrompt))],
            maxTokens: maxTokens ?? provider.maxOutputTokens ?? 500,
            system: .text(systemPrompt),
            stream: stream,
            temperature: 0.0
        )
    }

    /// Normalizes SDK errors into the app's AIError shape so retry logic keeps working.
    static func aiError(from error: Error) -> AIError {
        if case let OpenAIError.statusError(_, code) = error {
            return .apiError(statusCode: code, message: error.localizedDescription)
        }
        if let response = error as? APIErrorResponse {
            // Status code is not exposed by the SDK; assume server-side (retryable).
            return .apiError(statusCode: 500, message: response.errorDescription ?? "API error")
        }
        if case let SwiftAnthropic.APIError.responseUnsuccessful(description) = error,
           let code = statusCode(in: description) {
            return .apiError(statusCode: code, message: description)
        }
        if let anthropicError = error as? SwiftAnthropic.APIError {
            return .apiError(statusCode: 0, message: anthropicError.displayDescription)
        }
        return .apiError(statusCode: 0, message: error.localizedDescription)
    }

    private static func statusCode(in description: String) -> Int? {
        guard let range = description.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(description[range])
    }

    // MARK: - SDK Streaming

    /// Streaming through the MacPaw/OpenAI SDK.
    static func openAIStream(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int?,
        onDelta: ((String) -> Void)?
    ) async throws -> String {
        guard let client = openAIClient(provider: provider, apiKey: apiKey) else {
            throw AIError.invalidEndpoint
        }
        let query = openAIChatQuery(
            provider: provider, systemPrompt: systemPrompt, userPrompt: userPrompt,
            stream: true, maxTokens: maxTokens
        )
        var result = ""
        do {
            for try await chunk in client.chatsStream(query: query) {
                if let text = chunk.choices.first?.delta.content {
                    result += text
                    onDelta?(text)
                }
            }
            return result
        } catch {
            throw aiError(from: error)
        }
    }

    /// Streaming through the SwiftAnthropic SDK.
    static func claudeStream(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int?,
        onDelta: ((String) -> Void)?
    ) async throws -> String {
        let service = anthropicService(provider: provider, apiKey: apiKey)
        let parameter = claudeMessageParameter(
            provider: provider, systemPrompt: systemPrompt, userPrompt: userPrompt,
            stream: true, maxTokens: maxTokens
        )
        var result = ""
        do {
            for try await event in try await service.streamMessage(parameter) {
                if event.type == "content_block_delta", let text = event.delta?.text {
                    result += text
                    onDelta?(text)
                }
            }
            return result
        } catch {
            throw aiError(from: error)
        }
    }

    /// Legacy streaming path (Ollama's native `/api/chat` fallback).
    static func legacyStream(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int?,
        onDelta: ((String) -> Void)?
    ) async throws -> String {
        let request = try buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt, stream: true,
            maxTokens: maxTokens
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let body = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: http.statusCode, message: body)
        }

        return try await parseStream(bytes: bytes, providerType: provider.type, onDelta: onDelta)
    }

    // MARK: - SDK Non-Streaming

    /// Non-streaming request through the MacPaw/OpenAI SDK.
    static func openAINonStream(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int?
    ) async throws -> String {
        guard let client = openAIClient(provider: provider, apiKey: apiKey) else {
            throw AIError.invalidEndpoint
        }
        let query = openAIChatQuery(
            provider: provider, systemPrompt: systemPrompt, userPrompt: userPrompt,
            stream: false, maxTokens: maxTokens
        )
        do {
            let result = try await client.chats(query: query)
            guard let text = result.choices.first?.message.content else {
                throw AIError.invalidResponse
            }
            return text
        } catch let error as AIError {
            throw error
        } catch {
            throw aiError(from: error)
        }
    }

    /// Non-streaming request through the SwiftAnthropic SDK.
    static func claudeNonStream(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int?
    ) async throws -> String {
        let service = anthropicService(provider: provider, apiKey: apiKey)
        let parameter = claudeMessageParameter(
            provider: provider, systemPrompt: systemPrompt, userPrompt: userPrompt,
            stream: false, maxTokens: maxTokens
        )
        do {
            let response = try await service.createMessage(parameter)
            let text = response.content.compactMap { block -> String? in
                if case .text(let value, _) = block { return value }
                return nil
            }.joined()
            guard !text.isEmpty else { throw AIError.invalidResponse }
            return text
        } catch let error as AIError {
            throw error
        } catch {
            throw aiError(from: error)
        }
    }

    /// Legacy non-streaming path (Gemini, Ollama native fallback).
    static func legacyNonStream(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int?
    ) async throws -> String {
        let request = try buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt, stream: false,
            maxTokens: maxTokens
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: code, message: body)
        }

        return try extractResponse(from: data, type: provider.type)
    }
}
