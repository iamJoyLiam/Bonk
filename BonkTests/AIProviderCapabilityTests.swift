//
//  AIProviderCapabilityTests.swift
//  BonkTests
//

@testable import Bonk
import XCTest

final class AIProviderCapabilityTests: XCTestCase {
    func testOpenAIResponsesRouteUsesResponsesWireProtocol() {
        let config = AIProviderConfig(
            name: "OpenAI",
            type: .openAI,
            model: "gpt-5",
            endpoint: "https://api.openai.com",
            protocolType: .responses
        )

        let route = AIProviderCapabilityResolver.resolve(
            config: config, workload: .chat
        )

        XCTAssertEqual(route.wireProtocol, .openAIResponses)
        XCTAssertTrue(route.capability.supportsResponses)
        XCTAssertTrue(route.capability.supportsStreaming)
    }

    func testClaudeRouteDoesNotClaimOpenAIProtocolsOrToolCalling() {
        let config = AIProviderConfig(
            name: "Claude",
            type: .claude,
            model: "claude-sonnet-5",
            endpoint: "https://api.anthropic.com"
        )

        let route = AIProviderCapabilityResolver.resolve(
            config: config, workload: .agentToolLoop
        )

        XCTAssertEqual(route.wireProtocol, .anthropicMessages)
        XCTAssertFalse(route.capability.supportsChatCompletions)
        XCTAssertFalse(route.capability.supportsResponses)
        XCTAssertFalse(route.capability.supportsToolCalls)
    }

    func testCapabilityOverrideWinsOverProviderDefault() {
        let config = AIProviderConfig(
            name: "Custom",
            type: .custom,
            model: "unknown-model",
            endpoint: "https://example.com",
            capabilityOverride: ModelCapabilityOverride(
                supportsToolCalls: false,
                reasoningSupport: .unsupported
            )
        )

        let route = AIProviderCapabilityResolver.resolve(
            config: config, workload: .agentToolLoop
        )

        XCTAssertFalse(route.capability.supportsToolCalls)
        XCTAssertEqual(route.capability.reasoningSupport, .unsupported)
        XCTAssertEqual(route.source, .userOverride)
    }

    func testInlineWorkloadPrefersChatForResponsesCapableProvider() {
        let config = AIProviderConfig(
            name: "OpenAI",
            type: .openAI,
            model: "gpt-5",
            endpoint: "https://api.openai.com",
            protocolType: .responses
        )

        let route = AIProviderCapabilityResolver.resolve(
            config: config, workload: .inlineCompletion
        )

        XCTAssertEqual(route.wireProtocol, .openAIChatCompletions)
        XCTAssertEqual(route.source, .builtinModel)
    }

    func testUnsupportedResponsesOverrideFallsBackToChat() {
        let config = AIProviderConfig(
            name: "Gateway",
            type: .custom,
            model: "gateway-model",
            endpoint: "https://example.com",
            protocolType: .responses,
            capabilityOverride: ModelCapabilityOverride(
                supportsResponses: false,
                supportsChatCompletions: true
            )
        )

        let route = AIProviderCapabilityResolver.resolve(
            config: config, workload: .chat
        )

        XCTAssertEqual(route.wireProtocol, .openAIChatCompletions)
    }

    func testCapabilityProbeParsesNestedMetadata() throws {
        let config = AIProviderConfig(
            name: "Gateway",
            type: .custom,
            model: "demo",
            endpoint: "https://example.com"
        )
        let payload = """
        {
          "data": [{
            "id": "demo",
            "capabilities": {
              "supportsResponses": true,
              "supportsToolCalls": false,
              "reasoningSupport": "optional"
            }
          }]
        }
        """

        let snapshot = try XCTUnwrap(
            AIProviderCapabilityProbe.parse(
                data: Data(payload.utf8), provider: config
            )
        )

        XCTAssertTrue(snapshot.capability.supportsResponses)
        XCTAssertFalse(snapshot.capability.supportsToolCalls)
        XCTAssertEqual(snapshot.capability.reasoningSupport, .optional)
        XCTAssertEqual(snapshot.source, .dynamicProbe)
    }
}
