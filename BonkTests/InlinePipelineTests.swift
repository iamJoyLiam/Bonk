//
//  InlinePipelineTests.swift
//  BonkTests
//
//  Generation-safe commit + local/history path
//

@testable import Bonk
import XCTest

@MainActor
final class InlinePipelineTests: XCTestCase {
    func testPipelineHistoryInstant() async {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker",
            recentCommands: ["docker ps", "docker run -d nginx"],
            recentOutput: ""
        )
        pipeline.request(snapshot: snapshot)
        // Tier 1 (local/history/knownWords) commits synchronously — no debounce wait.
        XCTAssertNotNil(pipeline.suggestion)
        // Most recent is "docker run -d nginx" => suffix " run -d nginx" or display " run -d nginx" / "run -d nginx"
        // History source returns suffix with leading space handling via displaySuffix
        XCTAssertTrue(pipeline.suggestion?.text.contains("run") == true)
    }

    func testAlignedAcceptSuffix() {
        // Stale suggestion: generated for typed "do" ("cker ps"), line now ends "doc"
        XCTAssertEqual(CommandEditor.alignedAcceptSuffix(suggestion: "cker ps", rawLine: "user@host ~ % doc"), "ker ps")
        XCTAssertEqual(CommandEditor.alignedAcceptSuffix(suggestion: "cker", rawLine: "% doc"), "ker")
        // Aligned suggestion: no overlap with line tail — unchanged
        XCTAssertEqual(CommandEditor.alignedAcceptSuffix(suggestion: "ker ps", rawLine: "% doc"), "ker ps")
        // Leading-space suffix preserved when no overlap
        XCTAssertEqual(CommandEditor.alignedAcceptSuffix(suggestion: " ps", rawLine: "% docker"), " ps")
        // Nothing left after stripping overlap → nil
        XCTAssertNil(CommandEditor.alignedAcceptSuffix(suggestion: "c", rawLine: "% doc"))
        XCTAssertNil(CommandEditor.alignedAcceptSuffix(suggestion: "", rawLine: "% doc"))
    }

    func testPipelineGenerationGuard() async {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snap1 = CommandContextSnapshot(inputBuffer: "git", recentCommands: ["git status", "git log"], recentOutput: "")
        let snap2 = CommandContextSnapshot(inputBuffer: "docker", recentCommands: ["docker ps"], recentOutput: "")
        pipeline.request(snapshot: snap1)
        // Immediately bump generation with new request — old generation should not commit
        pipeline.request(snapshot: snap2)
        try? await Task.sleep(for: .milliseconds(800))
        // Should have docker suggestion, not git
        XCTAssertTrue(pipeline.suggestion?.text.contains("ps") == true || pipeline.suggestion?.displayText.contains("ps") == true)
    }

    func testPipelineCancelClears() async {
        let pipeline = InlineSuggestionPipeline()
        let snap = CommandContextSnapshot(inputBuffer: "docker", recentCommands: ["docker ps"], recentOutput: "")
        pipeline.request(snapshot: snap)
        pipeline.cancel()
        XCTAssertNil(pipeline.suggestion)
        XCTAssertFalse(pipeline.isRequesting)
    }

    func testVocabularyCompletesCommandToken() {
        let source = CommandVocabularySource()
        let snap = CommandContextSnapshot(inputBuffer: "dock", recentCommands: [], recentOutput: "")
        let sug = source.syncSuggestion(for: snap, typed: "dock")
        XCTAssertEqual(sug?.text, "er")
        XCTAssertEqual(sug?.displayText, "er")
        // No continuation when the token is already a full command
        let full = CommandContextSnapshot(inputBuffer: "docker", recentCommands: [], recentOutput: "")
        XCTAssertNil(source.syncSuggestion(for: full, typed: "docker"))
    }

    func testRankedCandidatesAndSelection() {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snap = CommandContextSnapshot(
            inputBuffer: "dock",
            recentCommands: ["docker ps"],
            recentOutput: "docker-desktop is running",
            knownWords: ["docker-desktop", "running"]
        )
        pipeline.request(snapshot: snap)
        // knownWords ("docker-desktop" → "er-desktop"), history ("er ps"), vocabulary ("er")
        XCTAssertGreaterThanOrEqual(pipeline.ranked.count, 3)
        // Default state is passive (no selection, but top recommended suggestion is visible)
        XCTAssertEqual(pipeline.engagement, .passive)
        XCTAssertNil(pipeline.selectedIndex)
        XCTAssertEqual(pipeline.suggestion?.text, "er-desktop")
        XCTAssertEqual(pipeline.suggestion?.fullText, "docker-desktop")
        // ↓ in passive state engages at index 0
        pipeline.moveSelection(1)
        XCTAssertEqual(pipeline.engagement, .engaged(index: 0))
        XCTAssertEqual(pipeline.selectedIndex, 0)
        XCTAssertEqual(pipeline.suggestion?.fullText, "docker-desktop")
        // Subsequent ↓ moves to candidate 1 (history)
        pipeline.moveSelection(1)
        XCTAssertEqual(pipeline.engagement, .engaged(index: 1))
        XCTAssertEqual(pipeline.selectedIndex, 1)
        XCTAssertTrue(pipeline.suggestion?.text.contains("ps") == true)
        XCTAssertEqual(pipeline.suggestion?.fullText, "docker ps")
        // ↓↓ clamps at the end instead of crashing
        pipeline.moveSelection(5)
        XCTAssertEqual(pipeline.suggestion?.text, "er")
        XCTAssertEqual(pipeline.suggestion?.fullText, "docker")
        // ↑↑↑ clamps back at the top (index 0)
        pipeline.moveSelection(-5)
        XCTAssertEqual(pipeline.selectedIndex, 0)
        XCTAssertEqual(pipeline.suggestion?.text, "er-desktop")
    }

    func testPipelineRejectFilters() async {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snap = CommandContextSnapshot(inputBuffer: "docker", recentCommands: ["docker ps"], recentOutput: "")
        pipeline.request(snapshot: snap)
        try? await Task.sleep(for: .milliseconds(800))
        let first = pipeline.suggestion
        print("[DBG] first=\(first?.text ?? "nil") display=\(first?.displayText ?? "nil")")
        XCTAssertNotNil(first)
        pipeline.rejectCurrent()
        XCTAssertNil(pipeline.suggestion)
        // Next request with same typed should be filtered if rejected
        pipeline.request(snapshot: snap)
        try? await Task.sleep(for: .milliseconds(800))
        print("[DBG] after reject second suggestion=\(pipeline.suggestion?.text ?? "nil")")
        // Rejected history should be filtered, so suggestion should be nil (or not equal to first)
        if let second = pipeline.suggestion {
            XCTAssertNotEqual(second.text, first?.text)
        } else {
            XCTAssertNil(pipeline.suggestion)
        }
    }
}
