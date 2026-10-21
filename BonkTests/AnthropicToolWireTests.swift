//
//  AnthropicToolWireTests.swift
//  BonkTests
//
//  Claude's agent tool loop.
//
//  The gap this closes: `ClaudeLLMProvider.toolCall` threw
//  "Claude tool loop is not enabled yet", so the default provider could not
//  use the agent's own headline feature. The Anthropic tool protocol is
//  also not a translation of the OpenAI one — a tool result is a *user*
//  message, tool arguments travel as an object, and the system prompt sits
//  outside the message list — so each of those rules is asserted here
//  rather than assumed.
//
//  The last test drives the provider's real request path through a stubbed
//  URLSession, so the shape on the wire is checked, not just the shape of
//  the helper that produces it.
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("Anthropic Tool Wire Tests")
struct AnthropicToolWireTests {

    // MARK: - Helpers

    private static func toolCall(id: String, name: String, arguments: String) -> LLMToolCall {
        LLMToolCall(id: id, name: name, argumentsJSON: arguments)
    }

    private static func blocks(_ message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]] ?? []
    }

    /// Bounds-safe access to a wire message.
    ///
    /// A raw `wire[2]` traps when the array is shorter than the index, which
    /// kills the test process and reports every other test as failed. A
    /// broken implementation has to fail one assertion, not take the suite
    /// down with it.
    private static func message(_ wire: [[String: Any]], at index: Int) -> [String: Any]? {
        guard wire.indices.contains(index) else { return nil }
        return wire[index]
    }

    private static func claudeConfig() -> AIProviderConfig {
        AIProviderConfig(
            name: "Claude",
            type: .claude,
            model: "claude-sonnet-5",
            endpoint: "https://example.invalid",
            apiKey: "test-key"
        )
    }

    // MARK: - Request shape

    @Test("The system prompt is a top-level field, not a message")
    func systemPromptIsNotAMessage() {
        let messages: [LLMMessage] = [
            .system("you are an agent"),
            .user("check the disk"),
        ]
        let body = AnthropicToolWire.requestBody(
            messages: messages, tools: [], model: "claude-sonnet-5", maxTokens: 1024
        )
        #expect(body["system"] as? String == "you are an agent")
        let wire = body["messages"] as? [[String: Any]] ?? []
        #expect(wire.allSatisfy { ($0["role"] as? String) != "system" },
                "Anthropic has no system role inside the message list")
    }

    @Test("A tool result is a user message that follows the assistant turn")
    func toolResultIsAUserMessage() {
        let messages: [LLMMessage] = [
            .user("check the disk"),
            LLMMessage(
                role: .assistant, content: "",
                toolCalls: [Self.toolCall(id: "toolu_1", name: "run_command", arguments: "{\"command\":\"df -h\"}")]
            ),
            LLMMessage(role: .tool, content: "Filesystem 90% full", toolCallID: "toolu_1"),
        ]
        let wire = AnthropicToolWire.payloadMessages(messages)
        #expect(wire.count == 3)
        #expect(Self.message(wire, at: 0)?["role"] as? String == "user")
        #expect(Self.message(wire, at: 1)?["role"] as? String == "assistant")
        #expect(Self.message(wire, at: 2)?["role"] as? String == "user",
                "a tool result rides in a user message, not an assistant one")

        let resultBlocks = Self.blocks(Self.message(wire, at: 2) ?? [:])
        #expect(resultBlocks.count == 1)
        #expect(resultBlocks.first?["type"] as? String == "tool_result")
        #expect(resultBlocks.first?["tool_use_id"] as? String == "toolu_1")
        #expect(resultBlocks.first?["content"] as? String == "Filesystem 90% full")
    }

    @Test("Consecutive tool results are merged into one user message")
    func consecutiveToolResultsMerge() {
        let messages: [LLMMessage] = [
            .user("check both"),
            LLMMessage(
                role: .assistant, content: "",
                toolCalls: [
                    Self.toolCall(id: "t1", name: "run_command", arguments: "{\"command\":\"df -h\"}"),
                    Self.toolCall(id: "t2", name: "run_command", arguments: "{\"command\":\"free -m\"}"),
                ]
            ),
            LLMMessage(role: .tool, content: "disk", toolCallID: "t1"),
            LLMMessage(role: .tool, content: "memory", toolCallID: "t2"),
        ]
        let wire = AnthropicToolWire.payloadMessages(messages)
        #expect(wire.count == 3, "both results belong to one user message")
        #expect(Self.message(wire, at: 2)?["role"] as? String == "user")
        #expect(Self.blocks(Self.message(wire, at: 2) ?? [:]).count == 2)
    }

    @Test("Tool arguments travel as an object, not as a JSON string")
    func toolArgumentsAreAnObject() {
        let messages: [LLMMessage] = [
            .user("run it"),
            LLMMessage(
                role: .assistant, content: "",
                toolCalls: [Self.toolCall(id: "t1", name: "run_command", arguments: "{\"command\":\"df -h\"}")]
            ),
        ]
        let wire = AnthropicToolWire.payloadMessages(messages)
        let use = Self.blocks(Self.message(wire, at: 1) ?? [:]).first ?? [:]
        #expect(use["type"] as? String == "tool_use")
        #expect(use["id"] as? String == "t1")
        #expect(use["name"] as? String == "run_command")
        let input = use["input"] as? [String: Any]
        #expect(input?["command"] as? String == "df -h",
                "the arguments must arrive as an object the API can validate")
    }

    @Test("A tool definition becomes an input_schema object")
    func toolDefinitionCarriesItsSchema() {
        let tool = LLMToolDefinition(
            name: "run_command",
            description: "Run a shell command",
            parametersJSON: """
            {"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
            """
        )
        let payload = AnthropicToolWire.toolPayload(tool)
        #expect(payload["name"] as? String == "run_command")
        #expect(payload["description"] as? String == "Run a shell command")
        let schema = payload["input_schema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        #expect(schema?["required"] as? [String] == ["command"])
    }

    @Test("The first wire message is a user message")
    func firstMessageIsUser() {
        let messages: [LLMMessage] = [
            .system("system"),
            .user("hello"),
        ]
        let wire = AnthropicToolWire.payloadMessages(messages)
        #expect(wire.first?["role"] as? String == "user")
    }

    // MARK: - Response shape

    @Test("A tool_use reply becomes a tool call with its arguments intact")
    func parsesToolUseReply() throws {
        let body = """
        {"content":[
          {"type":"text","text":"Checking now."},
          {"type":"tool_use","id":"toolu_abc","name":"run_command","input":{"command":"df -h"}}
        ],"stop_reason":"tool_use","usage":{"input_tokens":120,"output_tokens":35}}
        """
        let turn = try AnthropicToolWire.parseResponse(Data(body.utf8))
        #expect(turn.text == "Checking now.")
        #expect(turn.toolCalls.count == 1)
        #expect(turn.toolCalls[0].id == "toolu_abc")
        #expect(turn.toolCalls[0].name == "run_command")
        #expect(turn.toolCalls[0].arguments["command"] as? String == "df -h")
        #expect(turn.usage?.inputTokens == 120)
        #expect(turn.usage?.outputTokens == 35)
    }

    @Test("A reply truncated at the token limit produces no executable call")
    func truncatedReplyDropsToolCalls() throws {
        // The arguments were never finished being written. Running them would
        // execute a command with missing arguments.
        let body = """
        {"content":[
          {"type":"tool_use","id":"toolu_abc","name":"run_command","input":{"command":"df -h"}}
        ],"stop_reason":"max_tokens"}
        """
        let turn = try AnthropicToolWire.parseResponse(Data(body.utf8))
        #expect(turn.toolCalls.isEmpty,
                "a truncated tool call must not be executed")
    }

    @Test("Thinking blocks are neither text nor tool calls")
    func thinkingBlocksAreIgnored() throws {
        let body = """
        {"content":[
          {"type":"thinking","thinking":"let me check the disk","signature":"abc"},
          {"type":"text","text":"On it."}
        ],"stop_reason":"end_turn"}
        """
        let turn = try AnthropicToolWire.parseResponse(Data(body.utf8))
        #expect(turn.text == "On it.")
        #expect(turn.toolCalls.isEmpty)
    }

    @Test("A reply with no usage reports none, rather than zero")
    func missingUsageIsUnknown() throws {
        let turn = try AnthropicToolWire.parseResponse(Data("{\"content\":[]}".utf8))
        #expect(turn.usage == nil, "unreported usage must stay unknown, never zero")
    }

    // MARK: - The production request path

    @Test("The provider posts a well-formed Anthropic request and parses the reply")
    func providerPostsAnAnthropicRequest() async throws {
        StubHTTPURLProtocol.reset(for: "example.invalid")
        defer { StubHTTPURLProtocol.reset(for: "example.invalid") }
        StubHTTPURLProtocol.setResponse("""
        {"content":[
          {"type":"text","text":"Checking."},
          {"type":"tool_use","id":"toolu_1","name":"run_command","input":{"command":"df -h"}}
        ],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}
        """, for: "example.invalid")

        let provider = ClaudeLLMProvider(
            config: Self.claudeConfig(),
            apiKey: "test-key",
            session: StubHTTPURLProtocol.makeSession()
        )

        let turn = try await provider.toolCall(
            messages: [
                .system("you are an agent"),
                .user("check the disk"),
            ],
            tools: [
                LLMToolDefinition(
                    name: "run_command",
                    description: "Run a shell command",
                    parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
                ),
            ],
            maxTokens: 2048
        )

        // The reply was parsed.
        #expect(turn.toolCalls.count == 1)
        #expect(turn.toolCalls[0].name == "run_command")
        #expect(turn.toolCalls[0].arguments["command"] as? String == "df -h")

        // The request was well-formed.
        let request = try #require(StubHTTPURLProtocol.lastRequest(for: "example.invalid"))
        #expect(request.url.path == "/v1/messages")
        #expect(request.headers["x-api-key"] == "test-key")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(request.headers["content-type"] == "application/json")

        let decoded = try JSONSerialization.jsonObject(with: request.body)
        let body = try #require(decoded as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-5")
        #expect(body["max_tokens"] as? Int == 2048)
        #expect(body["system"] as? String == "you are an agent")
        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        #expect(tools?.first?["name"] as? String == "run_command")
        #expect(tools?.first?["input_schema"] != nil)
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
    }

    @Test("The provider no longer refuses the tool loop")
    func providerDoesNotRefuseToolCalls() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Bonk/Services/AI/Providers/ClaudeLLMProvider.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("not enabled yet"),
                "Claude must be able to use the agent tool loop")
    }

    @Test("Claude advertises tool-call support so the tool loop is selected")
    func claudeAdvertisesToolCalls() {
        let capability = AIProviderCapabilityResolver.providerDefaultCapability(
            for: Self.claudeConfig()
        )
        #expect(capability.supportsToolCalls,
                "the default provider has to reach the agent's own feature")
    }
}
