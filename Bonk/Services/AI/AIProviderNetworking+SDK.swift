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

    /// Provider-specific payload that disables reasoning/thinking for
    /// OpenAI-compatible APIs. Unknown providers get nil (no payload).
    static func reasoningDisablePayload(for type: AIProviderType) -> [String: Any]? {
        switch type {
        case .deepSeek: ["thinking": ["type": "disabled"]]
        case .qwen, .kimi: ["enable_thinking": false]
        default: nil
        }
    }

    /// Capability-driven variant. Provider type remains fallback for legacy
    /// networking paths; new adapters use model route capability.
    static func reasoningDisablePayload(
        for capability: ModelCapability
    ) -> [String: Any]? {
        switch capability.reasoningDisableStrategy {
        case .deepSeekThinkingDisabled:
            ["thinking": ["type": "disabled"]]
        case .enableThinkingFalse:
            ["enable_thinking": false]
        case .none:
            nil
        }
    }

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
            // Empty token must stay nil — the SDK otherwise sends
            // `Authorization: Bearer `, which proxies like litellm reject.
            token: provider.type.needsAPIKey && !apiKey.isEmpty ? apiKey : nil,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: 60,
            customHeaders: provider.extraHeaders
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
        // Empty/missing response body — typically a proxy or network hiccup.
        // Map to a retryable 500 so AIService's retry loop gets another chance,
        // and surface a readable message instead of "data couldn't be read".
        if let nsError = error as NSError?,
           nsError.domain == NSCocoaErrorDomain, nsError.code == 4865 {
            return .apiError(statusCode: 500, message: "Empty response from AI provider — check network or proxy")
        }
        return .apiError(statusCode: 0, message: error.localizedDescription)
    }

    private static func statusCode(in description: String) -> Int? {
        guard let range = description.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(description[range])
    }

    /// Legacy fallback is safe only when selected wire path is absent or
    /// returned an incompatible 200 payload. Auth, rate-limit, server, and
    /// timeout errors must surface without issuing a second request.
    static func shouldFallbackToLegacy(_ error: Error) -> Bool {
        guard let aiError = error as? AIError else { return false }
        return switch aiError {
        case .invalidResponse:
            true
        case let .apiError(statusCode, _):
            statusCode == 404 || statusCode == 405
        case .invalidEndpoint, .emptyResponse, .unsupported:
            false
        }
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
        disableReasoning: Bool,
        onDelta: ((String) -> Void)?
    ) async throws -> String {
        let request = try buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt, stream: true,
            maxTokens: maxTokens, disableReasoning: disableReasoning
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
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> String {
        let request = try buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt, stream: false,
            maxTokens: maxTokens, disableReasoning: disableReasoning
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError(statusCode: code, message: body)
        }

        return try extractResponse(from: data, type: provider.type)
    }

    // MARK: - Stream Parsing

    /// Extract incremental text from a streaming SSE event.
    static func extractDelta(from json: [String: Any]) -> String? {
        // OpenAI-compatible: choices[0].delta.content
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first
        {
            if let delta = first["delta"] as? [String: Any] {
                if let text = delta["content"] as? String {
                    return text
                }
                // Some providers use OpenAI content-part arrays.
                if let parts = delta["content"] as? [[String: Any]] {
                    let text = parts.compactMap { $0["text"] as? String }.joined()
                    if !text.isEmpty { return text }
                }
                // Legacy completions-compatible proxies may put text in delta.
                if let text = delta["text"] as? String {
                    return text
                }
            }
            if let text = first["text"] as? String {
                return text
            }
        }

        // Claude: type == "content_block_delta"
        if json["type"] as? String == "content_block_delta",
           let delta = json["delta"] as? [String: Any],
           let text = delta["text"] as? String
        { return text }

        // Ollama: message.content
        if let message = json["message"] as? [String: Any],
           let text = message["content"] as? String
        { return text }

        return nil
    }

    /// Parse an SSE stream and return the accumulated response text.
    /// Calls `onDelta` for each incremental chunk (caller controls UI cadence).
    static func parseStream(
        bytes: URLSession.AsyncBytes,
        providerType _: AIProviderType,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> String {
        var result = ""
        var buffer = Data()

        for try await byte in bytes {
            buffer.append(byte)
            // Decode whole lines at once so multi-byte UTF-8 (Chinese, emoji) survives.
            guard byte == 0x0A, let line = String(data: buffer, encoding: .utf8) else { continue }
            buffer = Data()

            guard line.hasPrefix("data: ") else { continue }
            let json = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
            guard json != "[DONE]",
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let text = extractDelta(from: obj) {
                result += text
                onDelta?(text)
            }
        }
        return result
    }
}
