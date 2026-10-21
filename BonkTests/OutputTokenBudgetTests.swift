//
//  OutputTokenBudgetTests.swift
//  BonkTests
//
//  The output token budget for one model turn.
//
//  The defect: the same model in the same conversation was answered within a
//  different budget depending on which code path it took. Claude's Ask mode
//  resolved 500 tokens, its agent tool loop 4096, OpenAI's chat 4096, its
//  tool loop 2000, and the Responses API 500 for chat and 2000 for the tool
//  loop. 500 tokens is roughly 350 words, so a long answer was cut
//  mid-sentence — and the path doing the most work per turn had the
//  smallest budget.
//
//  The fix routes every resolution through one resolver. These tests hold
//  that: the pure rules, the fact that the two paths of one provider now
//  agree, and a guard against a new hardcoded default creeping back in.
//

import Foundation
import Testing
@testable import Bonk

@Suite("Output token budget")
struct OutputTokenBudgetTests {

    // MARK: - Pure: the rules

    @Test("With nothing set, the fallback applies")
    func fallbackApplies() {
        #expect(OutputTokenBudget.resolve(requested: nil, providerType: .openAI)
            == OutputTokenBudget.fallback)
        #expect(OutputTokenBudget.resolve(requested: nil, providerType: .claude)
            == OutputTokenBudget.claude)
    }

    @Test("A saved setting is honoured exactly")
    func savedSettingIsHonoured() {
        #expect(OutputTokenBudget.resolve(requested: 12_000, providerType: .openAI) == 12_000)
        #expect(OutputTokenBudget.resolve(requested: 1, providerType: .openAI) == 1,
                "a small explicit budget is the user's decision")
    }

    @Test("A per-call request beats the saved setting")
    func perCallBeatsSaved() {
        let resolved = OutputTokenBudget.resolve(
            perCall: 900, saved: 12_000, providerType: .openAI
        )
        #expect(resolved == 900, "the per-call argument is the more specific instruction")
    }

    @Test("A non-positive setting is ignored rather than sent to the API")
    func nonPositiveIsIgnored() {
        #expect(OutputTokenBudget.resolve(requested: 0, providerType: .openAI)
            == OutputTokenBudget.fallback)
        #expect(OutputTokenBudget.resolve(requested: -5, providerType: .openAI)
            == OutputTokenBudget.fallback)
    }

    @Test("The fallback is large enough for a full answer")
    func fallbackIsUsable() {
        #expect(OutputTokenBudget.fallback >= 4_096,
                "500 tokens cut answers off mid-sentence")
    }

    // MARK: - Behavioural: the two paths of one provider agree

    /// The chat path and the tool path of the same provider, with the same
    /// saved settings, must resolve the same budget. They are not different
    /// kinds of question, so they are not different kinds of budget.
    @Test("Claude's chat path and tool path resolve the same budget")
    func claudePathsAgree() async throws {
        let config = AIProviderConfig(
            name: "Claude",
            type: .claude,
            model: "claude-sonnet-5",
            endpoint: "https://claude-budget.invalid",
            apiKey: "test-key"
        )

        // The chat path: the parameter the SDK is about to send.
        let chatBudget = AIProviderNetworking.claudeMessageParameter(
            provider: config,
            systemPrompt: "you are an assistant",
            userPrompt: "hello",
            stream: false,
            maxTokens: nil
        ).maxTokens

        // The tool path: the number that actually went out on the wire.
        StubHTTPURLProtocol.reset(for: "claude-budget.invalid")
        defer { StubHTTPURLProtocol.reset(for: "claude-budget.invalid") }
        StubHTTPURLProtocol.setResponse("{\"content\":[]}", for: "claude-budget.invalid")
        let provider = ClaudeLLMProvider(
            config: config,
            apiKey: "test-key",
            session: StubHTTPURLProtocol.makeSession()
        )
        _ = try await provider.toolCall(
            messages: [.system("s"), .user("u")],
            tools: [],
            maxTokens: nil
        )
        let request = try #require(StubHTTPURLProtocol.lastRequest(for: "claude-budget.invalid"))
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        let toolBudget = try #require(body["max_tokens"] as? Int)

        #expect(chatBudget == toolBudget,
                "the chat path and the tool path resolved different budgets: \(chatBudget) vs \(toolBudget)")
        #expect(chatBudget >= OutputTokenBudget.fallback,
                "the budget fell back to a value that truncates answers")
    }

    @Test("OpenAI's chat path and tool path resolve the same budget")
    func openAIPathsAgree() async throws {
        let config = AIProviderConfig(
            name: "OpenAI",
            type: .openAI,
            model: "gpt-4o",
            endpoint: "https://openai-budget.invalid",
            apiKey: "test-key"
        )

        let chatBudget = AIProviderNetworking.openAIChatQuery(
            provider: config,
            systemPrompt: "you are an assistant",
            userPrompt: "hello",
            stream: false,
            maxTokens: nil
        ).maxTokens

        StubHTTPURLProtocol.reset(for: "openai-budget.invalid")
        defer { StubHTTPURLProtocol.reset(for: "openai-budget.invalid") }
        StubHTTPURLProtocol.setResponse("{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}", for: "openai-budget.invalid")
        let provider = OpenAICompatibleLLMProvider(
            config: config,
            apiKey: "test-key",
            session: StubHTTPURLProtocol.makeSession()
        )
        _ = try await provider.toolCall(
            messages: [.system("s"), .user("u")],
            tools: [],
            maxTokens: nil
        )
        let request = try #require(StubHTTPURLProtocol.lastRequest(for: "openai-budget.invalid"))
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        let toolBudget = try #require(body["max_tokens"] as? Int)

        #expect(chatBudget == toolBudget,
                "the chat path and the tool path resolved different budgets: \(chatBudget ?? -1) vs \(toolBudget)")
    }

    @Test("A saved setting reaches the wire on both paths")
    func savedSettingReachesTheWire() async throws {
        let config = AIProviderConfig(
            name: "OpenAI",
            type: .openAI,
            model: "gpt-4o",
            endpoint: "https://openai-saved-budget.invalid",
            apiKey: "test-key",
            maxOutputTokens: 7_777
        )
        StubHTTPURLProtocol.reset(for: "openai-saved-budget.invalid")
        defer { StubHTTPURLProtocol.reset(for: "openai-saved-budget.invalid") }
        StubHTTPURLProtocol.setResponse("{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}", for: "openai-saved-budget.invalid")
        let provider = OpenAICompatibleLLMProvider(
            config: config,
            apiKey: "test-key",
            session: StubHTTPURLProtocol.makeSession()
        )
        _ = try await provider.toolCall(
            messages: [.user("u")], tools: [], maxTokens: nil
        )
        let request = try #require(StubHTTPURLProtocol.lastRequest(for: "openai-saved-budget.invalid"))
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        #expect(body["max_tokens"] as? Int == 7_777,
                "the user's setting must reach the provider")
    }

    // MARK: - Guard against a new hardcoded default

    @Test("No path resolves a token budget on its own")
    func noPathHasItsOwnDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Bonk/Services/AI")

        let offenders: [String] = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") && $0 != "OutputTokenBudget.swift" }
            .compactMap { name -> String? in
                let source = try String(
                    contentsOf: root.appendingPathComponent(name),
                    encoding: .utf8
                )
                // A `?? 500` / `?? 2000` / `?? 4096` on a token budget is the
                // shape the defect had: the same decision, answered
                // differently depending on the path.
                let pattern = #"maxTokens[^\n]*\?\?[^\n]*\b(500|2000|4096)\b"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
                let range = NSRange(source.startIndex..., in: source)
                guard regex.firstMatch(in: source, range: range) != nil else { return nil }
                return name
            }
        #expect(offenders.isEmpty,
                "these files resolve a token budget on their own: \(offenders)")
    }
}
