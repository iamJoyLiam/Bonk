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
        // Wait for debounce (500ms) + pipeline perform
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(pipeline.suggestion)
        // Most recent is "docker run -d nginx" => suffix " run -d nginx" or display " run -d nginx" / "run -d nginx"
        // History source returns suffix with leading space handling via displaySuffix
        XCTAssertTrue(pipeline.suggestion?.text.contains("run") == true)
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
