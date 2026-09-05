//
//  LLMCompletionAdapterContractTests.swift
//  BonkTests
//
//  Commit 0.3 UX Contract Tests: LLMCompletionAdapter Validation & Rejection
//

@testable import Bonk
import XCTest

final class LLMCompletionAdapterContractTests: XCTestCase {
    // MARK: - Test 1: Conversational chatter rejected
    func testConversationalChatterRejected() {
        let raw = "Sure! Here is the command you are looking for: git checkout"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "git che")
        XCTAssertNil(adapted, "Conversational responses must be strictly rejected")
    }

    // MARK: - Test 2: Reasoning tags stripped
    func testReasoningTagsStripped() {
        let raw = "<think>The user wants to checkout a branch.</think> git checkout"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "git che")
        XCTAssertNotNil(adapted, "Reasoning tags must be stripped, preserving valid completion")
        XCTAssertEqual(adapted?.text, "ckout")
    }

    // MARK: - Test 3: Unclosed think tag stripped to empty
    func testUnclosedThinkTagStripped() {
        let raw = "<think>Still thinking about docker..."
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "docker")
        XCTAssertNil(adapted, "Unclosed think tags must strip to nil")
    }

    // MARK: - Test 4: Single random letter rejected
    func testSingleRandomLetterRejected() {
        let raw = "e"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "git ch")
        XCTAssertNil(adapted, "Single character continuation must be rejected to prevent stuttering ghost text")
    }

    // MARK: - Test 5: Single flag continuation accepted
    func testSingleFlagContinuationAccepted() {
        let raw = " -a"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "docker ps")
        XCTAssertNotNil(adapted, "Single-letter flags (like -a) are valid shell syntax and must be accepted")
        XCTAssertEqual(adapted?.text, " -a")
    }

    // MARK: - Test 6: Markdown code block stripped
    func testMarkdownCodeBlockStripped() {
        let raw = "```bash\ngit checkout -b feature\n```"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "git che")
        XCTAssertNotNil(adapted)
        XCTAssertEqual(adapted?.text, "ckout -b feature")
    }

    // MARK: - Test 7: Non-continuation rejected
    func testNonContinuationRejected() {
        let raw = "commit -m 'test'"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "git che")
        XCTAssertNil(adapted, "Mismatched token prefix continuation must be rejected")
    }

    // MARK: - Test 8: Valid continuation accepted
    func testValidContinuationAccepted() {
        let raw = "git checkout"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "git che")
        XCTAssertNotNil(adapted)
        XCTAssertEqual(adapted?.text, "ckout")
    }

    // MARK: - Test 9: Natural language intent strips markdown code blocks
    func testNaturalLanguageMarkdownStripped() {
        let raw = "```bash\ndocker ps\n```"
        let adapted = LLMCompletionAdapter.adaptNaturalLanguage(rawOutput: raw, typed: "# list containers")
        XCTAssertNotNil(adapted)
        XCTAssertEqual(adapted?.fullText, "docker ps")
        XCTAssertEqual(adapted?.displayText, " -> docker ps")
        let backspaces = String(repeating: "\u{7F}", count: "# list containers".count)
        XCTAssertEqual(adapted?.text, backspaces + "docker ps")
    }

    // MARK: - Test 10: Natural language intent strips reasoning tags
    func testNaturalLanguageReasoningStripped() {
        let raw = "<think>The user wants to find swift files.</think>find . -name \"*.swift\""
        let adapted = LLMCompletionAdapter.adaptNaturalLanguage(rawOutput: raw, typed: "# 查找swift文件")
        XCTAssertNotNil(adapted)
        XCTAssertEqual(adapted?.fullText, "find . -name \"*.swift\"")
        XCTAssertEqual(adapted?.displayText, " -> find . -name \"*.swift\"")
    }

    // MARK: - Test 11: Natural language intent rejects conversational chatter
    func testNaturalLanguageConversationalRejected() {
        let raw = "Here is the command you can run to list containers: docker ps"
        let adapted = LLMCompletionAdapter.adaptNaturalLanguage(rawOutput: raw, typed: "# list containers")
        XCTAssertNil(adapted, "Conversational responses must be strictly rejected")
    }

    // MARK: - Test 12: Natural language intent rejects repeated query
    func testNaturalLanguageRepeatedQueryRejected() {
        let raw = "list containers"
        let adapted = LLMCompletionAdapter.adaptNaturalLanguage(rawOutput: raw, typed: "# list containers")
        XCTAssertNil(adapted, "Echoed query without translation must be rejected")
    }
}
