//
//  AgentToolTests.swift
//  BonkTests
//

@testable import Bonk
import XCTest

final class AgentToolTests: XCTestCase {
    // MARK: - parseAgentTurn

    func testParseContentOnlyTurn() throws {
        let data = Data(
            """
            {
              "choices": [
                {
                  "message": {
                    "content": "Done. List is 12 files.",
                    "tool_calls": null
                  }
                }
              ]
            }
            """.utf8
        )
        let turn = try AIProviderNetworking.parseAgentTurn(from: data)
        XCTAssertEqual(turn.content, "Done. List is 12 files.")
        XCTAssertTrue(turn.toolCalls.isEmpty)
    }

    func testParseToolCallTurn() throws {
        let data = Data(
            """
            {
              "choices": [
                {
                  "message": {
                    "content": null,
                    "tool_calls": [
                      {
                        "id": "call_1",
                        "type": "function",
                        "function": {
                          "name": "run_command",
                          "arguments": "{\\"command\\":\\"ls -la /var/www\\"}"
                        }
                      }
                    ]
                  }
                }
              ]
            }
            """.utf8
        )
        let turn = try AIProviderNetworking.parseAgentTurn(from: data)
        XCTAssertNil(turn.content)
        XCTAssertEqual(turn.toolCalls.count, 1)
        XCTAssertEqual(turn.toolCalls[0].id, "call_1")
        XCTAssertEqual(turn.toolCalls[0].name, "run_command")
        XCTAssertEqual(turn.toolCalls[0].arguments["command"] as? String, "ls -la /var/www")
    }

    func testParseSkipsMalformedToolCall() throws {
        let data = Data(
            """
            {
              "choices": [
                {
                  "message": {
                    "content": "ok",
                    "tool_calls": [
                      { "id": "x", "type": "function", "function": {} }
                    ]
                  }
                }
              ]
            }
            """.utf8
        )
        let turn = try AIProviderNetworking.parseAgentTurn(from: data)
        XCTAssertEqual(turn.content, "ok")
        XCTAssertTrue(turn.toolCalls.isEmpty)
    }

    func testParseInvalidPayloadThrows() {
        let data = Data("{\"unexpected\": true}".utf8)
        XCTAssertThrowsError(try AIProviderNetworking.parseAgentTurn(from: data))
    }
}
