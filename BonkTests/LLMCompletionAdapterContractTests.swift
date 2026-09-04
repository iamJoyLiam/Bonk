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
}
