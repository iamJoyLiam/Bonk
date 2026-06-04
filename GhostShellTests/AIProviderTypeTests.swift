//
//  AIProviderTypeTests.swift
//  GhostShellTests
//

import XCTest
@testable import GhostShell

final class AIProviderTypeTests: XCTestCase {

    func testAllCasesHaveDisplayNames() {
        for type in AIProviderType.allCases {
            XCTAssertFalse(type.displayName.isEmpty, "\(type) should have a display name")
        }
    }

    func testAllCasesHaveSymbolNames() {
        for type in AIProviderType.allCases {
            XCTAssertFalse(type.symbolName.isEmpty, "\(type) should have a symbol name")
        }
    }

    func testClaudeDefaultEndpoint() {
        XCTAssertEqual(AIProviderType.claude.defaultEndpoint, "https://api.anthropic.com")
    }

    func testOpenAIDefaultEndpoint() {
        XCTAssertEqual(AIProviderType.openAI.defaultEndpoint, "https://api.openai.com")
    }

    func testOllamaDefaultEndpoint() {
        XCTAssertEqual(AIProviderType.ollama.defaultEndpoint, "http://localhost:11434")
    }

    func testOllamaDoesNotNeedAPIKey() {
        XCTAssertFalse(AIProviderType.ollama.needsAPIKey)
    }

    func testCopilotDoesNotNeedAPIKey() {
        XCTAssertFalse(AIProviderType.copilot.needsAPIKey)
    }

    func testClaudeNeedsAPIKey() {
        XCTAssertTrue(AIProviderType.claude.needsAPIKey)
    }

    func testDefaultModels() {
        XCTAssertFalse(AIProviderType.claude.defaultModel.isEmpty)
        XCTAssertFalse(AIProviderType.openAI.defaultModel.isEmpty)
        XCTAssertFalse(AIProviderType.gemini.defaultModel.isEmpty)
    }
}
