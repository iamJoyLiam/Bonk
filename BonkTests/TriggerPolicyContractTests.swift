//
//  TriggerPolicyContractTests.swift
//  BonkTests
//
//  Commit 0.2 UX Contract Tests: InlineTriggerPolicy Decision Boundary
//

@testable import Bonk
import XCTest

final class TriggerPolicyContractTests: XCTestCase {
    // MARK: - Test 1: Input too short (< 2 chars) -> Never trigger LLM
    func testInputTooShortDoesNotTriggerLLM() {
        let snapshot = CommandContextSnapshot(inputBuffer: "g")
        let decision = InlineTriggerPolicy.evaluate(
            typed: "g",
            snapshot: snapshot,
            confidence: .low
        )
        XCTAssertFalse(decision.shouldRequestLLM, "Typing 1 character must never trigger LLM")
        XCTAssertEqual(decision.reason, .inputTooShort)
    }

    // MARK: - Test 2: High deterministic confidence -> Skip LLM
    func testDeterministicHighConfidenceSkipsLLM() {
        let snapshot = CommandContextSnapshot(inputBuffer: "docker ps")
        let highConf = DeterministicConfidence.high(candidate: Suggestion(text: " -a", displayText: " -a"))
        let decision = InlineTriggerPolicy.evaluate(
            typed: "docker ps",
            snapshot: snapshot,
            confidence: highConf
        )
        XCTAssertFalse(decision.shouldRequestLLM, "High deterministic confidence must completely suppress LLM")
        XCTAssertEqual(decision.reason, .deterministicHighConfidence)
    }

    // MARK: - Test 3: Cursor in middle of a word -> Suppress LLM
    func testCursorInMiddleOfTokenSuppressesLLM() {
        // "checkout" with cursor at index 3: "che|ckout"
        let snapshot = CommandContextSnapshot(inputBuffer: "checkout", cursorOffset: 3)
        let decision = InlineTriggerPolicy.evaluate(
            typed: "checkout",
            snapshot: snapshot,
            confidence: .low
        )
        XCTAssertFalse(decision.shouldRequestLLM, "Cursor inside a word must not trigger LLM completion")
        XCTAssertEqual(decision.reason, .cursorInMiddleOfToken)
    }

    // MARK: - Test 4: Cursor at token boundary -> Allows completion evaluation
    func testCursorAtTokenBoundaryAllowsTriggering() {
        // "git checkout " with cursor at end (index 13, following whitespace)
        let snapshot = CommandContextSnapshot(inputBuffer: "git checkout ", cursorOffset: 13)
        let decision = InlineTriggerPolicy.evaluate(
            typed: "git checkout ",
            snapshot: snapshot,
            confidence: .low
        )
        XCTAssertTrue(decision.shouldRequestLLM, "Cursor at token boundary must allow LLM completion")
        XCTAssertEqual(decision.reason, .noDeterministicCandidate)
    }

    // MARK: - Test 5: Low confidence -> Triggers LLM with standard debounce (220ms)
    func testNoDeterministicCandidateTriggersLLMWithDebounce() {
        let snapshot = CommandContextSnapshot(inputBuffer: "custom-tool --flag")
        let decision = InlineTriggerPolicy.evaluate(
            typed: "custom-tool --flag",
            snapshot: snapshot,
            confidence: .low
        )
        XCTAssertTrue(decision.shouldRequestLLM)
        XCTAssertEqual(decision.reason, .noDeterministicCandidate)
        XCTAssertEqual(decision.debounceMs, 220)
    }

    // MARK: - Test 6: Natural language intent -> Triggers LLM with fast debounce (150ms)
    func testNaturalLanguageIntentTriggersLLMWithFastDebounce() {
        let snapshot = CommandContextSnapshot(inputBuffer: "# 查看未使用的容器")
        let decision = InlineTriggerPolicy.evaluate(
            typed: "# 查看未使用的容器",
            snapshot: snapshot,
            confidence: .low
        )
        XCTAssertTrue(decision.shouldRequestLLM)
        XCTAssertEqual(decision.reason, .naturalLanguageIntent)
        XCTAssertEqual(decision.debounceMs, 150)
    }

    // MARK: - Test 7: Pipeline skips LLM when deterministic candidate exists
    @MainActor
    func testPipelineSkipsLLMWhenDeterministicCandidateExists() async {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker",
            recentCommands: ["docker ps -a"],
            recentOutput: ""
        )

        pipeline.request(snapshot: snapshot)

        // Local candidate commits immediately
        XCTAssertNotNil(pipeline.suggestion)
        XCTAssertEqual(pipeline.suggestion?.text, " ps -a")

        // Because confidence is high, LLM is never requested (isRequesting stays false)
        XCTAssertFalse(pipeline.isRequesting)
    }

    // MARK: - Test 8: Single character root triggers 350ms delay tier without LLM
    func testSingleCharacterRootUses350msTier() {
        let snapshot = CommandContextSnapshot(inputBuffer: "d")
        let decision = InlineTriggerPolicy.evaluate(
            typed: "d",
            snapshot: snapshot,
            confidence: .low
        )
        XCTAssertFalse(decision.shouldRequestLLM)
        XCTAssertEqual(decision.debounceMs, 350)
        XCTAssertEqual(decision.tier, .singleCharDelay)
    }

    // MARK: - Test 9: Parameter completion (trailing space) triggers 80ms fast tier
    func testParameterCompletionUses80msFastTier() {
        let snapshot = CommandContextSnapshot(inputBuffer: "docker ")
        let decision = InlineTriggerPolicy.evaluate(
            typed: "docker ",
            snapshot: snapshot,
            confidence: .low
        )
        XCTAssertTrue(decision.shouldRequestLLM)
        XCTAssertEqual(decision.debounceMs, 80)
        XCTAssertEqual(decision.tier, .parameter)
    }

    // MARK: - Test 10: Explicit hotkey trigger uses 0ms immediate tier
    func testExplicitHotkeyUses0msImmediateTier() {
        let snapshot = CommandContextSnapshot(inputBuffer: "randomcmd")
        let decision = InlineTriggerPolicy.evaluate(
            typed: "randomcmd",
            snapshot: snapshot,
            confidence: .low,
            isExplicitHotkey: true
        )
        XCTAssertTrue(decision.shouldRequestLLM)
        XCTAssertEqual(decision.debounceMs, 0)
        XCTAssertEqual(decision.tier, .immediate)
        XCTAssertEqual(decision.reason, .explicitAIRequest)
    }
}
