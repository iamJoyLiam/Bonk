//
//  AnthropicToolWire.swift
//  Bonk
//
//  Anthropic Messages API translation for the agent tool loop.
//
//  Deliberately free of I/O. The rules that actually decide whether a
//  Claude agent works are all in here, and none of them need a network to
//  check:
//
//  - a tool result is a **user** message, not an assistant message, and it
//    has to ride directly after the assistant turn that asked for it;
//  - tool arguments travel as a JSON object, not as a JSON string;
//  - a response cut at the token limit must not produce an executable tool
//    call, because the arguments were never finished being written.
//
//  The SwiftAnthropic SDK is still used for the plain chat and streaming
//  paths. It is not used here because its tool_use input type is a typed
//  enum, and mapping arbitrary tool arguments through it would be lossy.
//

import Foundation

enum AnthropicToolWire {

    // MARK: - Request

    /// Build the request body for a tool-enabled turn.
    static func requestBody(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        model: String,
        maxTokens: Int
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": payloadMessages(messages),
        ]
        let system = systemText(messages)
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty { body["tools"] = tools.map(toolPayload) }
        return body
    }

    /// The system prompt. Anthropic carries it outside the message list, as
    /// its own top-level field.
    static func systemText(_ messages: [LLMMessage]) -> String {
        messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    /// One wire message: a role and its content blocks.
    private struct WireMessage {
        var role: String
        var blocks: [[String: Any]]
    }

    /// Convert the conversation into Anthropic's message array.
    ///
    /// Three rules the wire format imposes:
    ///
    /// 1. Only `user` and `assistant` roles exist. The system prompt is a
    ///    top-level field, and a tool result is a **user** message — the
    ///    result is something the tool told the user, not something the
    ///    assistant said.
    /// 2. A tool result must ride in the user message directly after the
    ///    assistant turn that asked for it. Consecutive results are merged
    ///    into one user message, which is the shape the API documents.
    /// 3. Consecutive same-role messages are merged, so the array never
    ///    contains two user messages in a row.
    static func payloadMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        var entries: [WireMessage] = []

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                append(
                    role: "user",
                    blocks: [textBlock(message.content)],
                    to: &entries
                )
            case .assistant:
                var blocks: [[String: Any]] = []
                if !message.content.isEmpty {
                    blocks.append(textBlock(message.content))
                }
                for call in message.toolCalls ?? [] {
                    blocks.append(toolUseBlock(call))
                }
                guard !blocks.isEmpty else { continue }
                append(role: "assistant", blocks: blocks, to: &entries)
            case .tool:
                guard let callID = message.toolCallID else { continue }
                append(
                    role: "user",
                    blocks: [toolResultBlock(callID: callID, content: message.content)],
                    to: &entries
                )
            }
        }

        return entries.map { ["role": $0.role, "content": $0.blocks] }
    }

    /// Merge a message into the last entry when the role matches.
    ///
    /// Inside a user message, tool results come first. The API reads
    /// everything after a tool_result block as the user's own words, so text
    /// that followed a result would be read as the user answering it.
    private static func append(
        role: String,
        blocks: [[String: Any]],
        to entries: inout [WireMessage]
    ) {
        guard entries.last?.role == role else {
            entries.append(WireMessage(role: role, blocks: blocks))
            return
        }
        guard role == "user" else {
            entries[entries.count - 1].blocks.append(contentsOf: blocks)
            return
        }
        func isResult(_ block: [String: Any]) -> Bool {
            (block["type"] as? String) == "tool_result"
        }
        let existing = entries[entries.count - 1].blocks
        let existingResults = existing.filter(isResult)
        let existingRest = existing.filter { !isResult($0) }
        let incomingResults = blocks.filter(isResult)
        let incomingRest = blocks.filter { !isResult($0) }
        entries[entries.count - 1].blocks =
            existingResults + incomingResults + existingRest + incomingRest
    }

    /// Anthropic's `tools` entry. `input_schema` is a JSON Schema object;
    /// our definitions carry it as a string.
    static func toolPayload(_ tool: LLMToolDefinition) -> [String: Any] {
        var payload: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let data = tool.parametersJSON.data(using: .utf8),
           let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            payload["input_schema"] = schema
        } else {
            payload["input_schema"] = ["type": "object", "properties": [:]]
        }
        return payload
    }

    private static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private static func toolUseBlock(_ call: LLMToolCall) -> [String: Any] {
        var block: [String: Any] = [
            "type": "tool_use",
            "id": call.id,
            "name": call.name,
        ]
        // Anthropic wants the arguments as an object. Our side carries them
        // as the JSON string the model produced, so it is parsed back.
        let parsed = call.argumentsJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        block["input"] = parsed ?? [:]
        return block
    }

    private static func toolResultBlock(callID: String, content: String) -> [String: Any] {
        [
            "type": "tool_result",
            "tool_use_id": callID,
            "content": content,
        ]
    }

    // MARK: - Response

    /// Parse an Anthropic Messages response into the app's turn shape.
    static func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }
        let stopReason = json["stop_reason"] as? String
        var textParts: [String] = []
        var calls: [LLMToolCall] = []

        for block in contentBlocks(in: json) {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String
                else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let argumentsJSON = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                calls.append(
                    LLMToolCall(id: id, name: name, argumentsJSON: argumentsJSON)
                )
            default:
                // `thinking` and `redacted_thinking` blocks are reasoning.
                // They are neither assistant text nor tool calls.
                continue
            }
        }

        // A response cut at the token limit can carry a tool_use block whose
        // input never finished being written. Running it would execute a
        // command with missing arguments, so the call is dropped and the
        // model is asked again instead.
        if stopReason == "max_tokens" {
            calls = []
        }

        return LLMResponse(
            text: textParts.joined(separator: "\n"),
            toolCalls: calls,
            usage: TokenUsage.anthropic(from: json["usage"] as? [String: Any])
        )
    }

    /// The `content` array. Anthropic always sends an array, but a proxy in
    /// front of it may flatten the reply to a bare string.
    private static func contentBlocks(in json: [String: Any]) -> [[String: Any]] {
        if let blocks = json["content"] as? [[String: Any]] { return blocks }
        if let text = json["content"] as? String, !text.isEmpty {
            return [["type": "text", "text": text]]
        }
        return []
    }
}
