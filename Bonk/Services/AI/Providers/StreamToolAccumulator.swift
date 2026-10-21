//
//  StreamToolAccumulator.swift
//  Bonk
//
//  Turning a streaming turn back into text and tool calls.
//
//  The agent loop needs a turn that streams *and* carries tool calls: the
//  model writes its answer as it goes, and then — or instead — asks for a
//  command to run. Both halves arrive interleaved on the wire.
//
//  These accumulators are pure: a string in, state out. The wire formats are
//  the fiddly part (fragments arrive out of order, split across chunks,
//  sometimes forged by a hostile endpoint), and keeping them away from the
//  transport is what makes them testable at all.
//
//  Two formats:
//
//  * OpenAI-compatible — `choices[0].delta.tool_calls[]`, each fragment
//    carrying an `index`; the first fragment of a call carries the id and
//    the name, the rest carry argument fragments.
//
//  * Anthropic — `content_block_start` opens a block (text or tool_use) and
//    `content_block_delta` carries its content; a tool's arguments arrive as
//    `input_json_delta` fragments.
//

import Foundation

// MARK: - OpenAI-compatible

/// Accumulates an OpenAI-compatible SSE stream.
struct OpenAIStreamAccumulator {
    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: PartialCall] = [:]

    /// The text the model has written so far.
    private(set) var text = ""
    /// The reasoning the model has published so far, if the provider sends it.
    private(set) var reasoning = ""
    /// The usage the provider reported, if it reported any.
    private(set) var usage: TokenUsage?

    /// The tool calls, in the order the model asked for them.
    ///
    /// Ordered by the model's own index, not by arrival: the fragments of one
    /// call can arrive interleaved with the fragments of another, and
    /// running them in arrival order would run the model's second command
    /// first.
    var toolCalls: [LLMToolCall] {
        partials.keys.sorted().compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            return LLMToolCall(
                id: partial.id,
                name: partial.name,
                argumentsJSON: partial.arguments
            )
        }
    }

    /// Consume one SSE `data:` payload and report what it added.
    ///
    /// The events come back so the caller can emit them *now*. A parser that
    /// accumulated first and reported at the end would defeat the point of
    /// streaming: the user would still see nothing until the turn was over.
    ///
    /// A payload that cannot be understood is ignored rather than fatal: a
    /// provider that adds a field Bonk does not know about should not break
    /// the run.
    mutating func ingest(_ payload: String) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "[DONE]",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return events }

        if object["usage"] is [String: Any] {
            usage = TokenUsage.chatCompletions(from: object)
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let delta = choice["delta"] as? [String: Any]
        else { return events }

        if let content = delta["content"] as? String, !content.isEmpty {
            text += content
            events.append(.textDelta(content))
        }
        // Reasoning arrives under different names depending on the provider.
        // DeepSeek and the OpenAI-compatible servers call it
        // `reasoning_content`; some call it `reasoning`.
        if let reasoningDelta = (delta["reasoning_content"] as? String)
            ?? (delta["reasoning"] as? String), !reasoningDelta.isEmpty {
            reasoning += reasoningDelta
            events.append(.reasoning(reasoningDelta))
        }
        guard let fragments = delta["tool_calls"] as? [[String: Any]] else { return events }
        for fragment in fragments {
            let index = fragment["index"] as? Int ?? 0
            if partials[index] == nil {
                partials[index] = PartialCall()
            }
            guard var partial = partials[index] else { continue }
            if let id = fragment["id"] as? String, !id.isEmpty {
                partial.id = id
            }
            if let function = fragment["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty {
                    partial.name = name
                }
                if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                    partial.arguments += arguments
                }
            }
            partials[index] = partial
        }
        return events
    }
}

// MARK: - Anthropic

/// Accumulates an Anthropic SSE stream.
struct AnthropicStreamAccumulator {
    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var partials: [Int: PartialCall] = [:]
    private var blockIsTool: [Int: Bool] = [:]

    private(set) var text = ""
    private(set) var reasoning = ""
    private(set) var usage: TokenUsage?
    private var inputTokens: Int?
    private var outputTokens: Int?

    /// The tool calls, in the order the model asked for them.
    ///
    /// Ordered by the model's own index, not by arrival: the fragments of one
    /// call can arrive interleaved with the fragments of another, and
    /// running them in arrival order would run the model's second command
    /// first.
    var toolCalls: [LLMToolCall] {
        partials.keys.sorted().compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            return LLMToolCall(
                id: partial.id,
                name: partial.name,
                argumentsJSON: partial.arguments
            )
        }
    }

    /// Consume one SSE `data:` payload and report what it added.
    ///
    /// The events come back so the caller can emit them *now* — a parser
    /// that reported at the end would defeat the point of streaming.
    mutating func ingest(_ payload: String) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return events }

        switch type {
        case "message_start":
            let message = object["message"] as? [String: Any]
            if let reported = message?["usage"] as? [String: Any] {
                inputTokens = reported["input_tokens"] as? Int
                outputTokens = reported["output_tokens"] as? Int
            }
        case "content_block_start":
            guard let index = object["index"] as? Int,
                  let block = object["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String
            else { return events }
            if blockType == "tool_use" {
                var partial = PartialCall()
                partial.id = block["id"] as? String ?? ""
                partial.name = block["name"] as? String ?? ""
                partials[index] = partial
                blockIsTool[index] = true
            } else {
                blockIsTool[index] = false
            }
        case "content_block_delta":
            guard let index = object["index"] as? Int,
                  let delta = object["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String
            else { return events }
            switch deltaType {
            case "text_delta":
                if let chunk = delta["text"] as? String {
                    text += chunk
                    events.append(.textDelta(chunk))
                }
            case "thinking_delta":
                if let chunk = delta["thinking"] as? String {
                    reasoning += chunk
                    events.append(.reasoning(chunk))
                }
            case "input_json_delta":
                guard var partial = partials[index] else { return events }
                if let chunk = delta["partial_json"] as? String {
                    partial.arguments += chunk
                }
                partials[index] = partial
            default:
                break
            }
        case "message_delta":
            if let reported = object["usage"] as? [String: Any] {
                if let count = reported["output_tokens"] as? Int { outputTokens = count }
                if let count = reported["input_tokens"] as? Int { inputTokens = count }
            }
        default:
            break
        }

        if inputTokens != nil || outputTokens != nil {
            usage = TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: nil
            )
        }
        return events
    }
}
