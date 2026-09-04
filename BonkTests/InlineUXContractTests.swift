//  InlineUXContractTests.swift
//  BonkTests
//
//  End-to-end UX contract test suite for Inline AI Interaction Layer (P0.5).
//  Validates the full chain: Context -> TriggerPolicy -> Ranker -> PresentationPolicy.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Inline UX Contract Tests")
@MainActor
struct InlineUXContractTests {

    @Test("Deterministic local history always appears instantly without being blocked by typing speed")
    func deterministicHistoryAppearsInstantly() {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker",
            recentCommands: ["docker run -d redis"],
            recentOutput: ""
        )

        pipeline.request(snapshot: snapshot)

        #expect(pipeline.suggestion != nil)
        #expect(pipeline.suggestion?.fullText == "docker run -d redis")
    }

    @Test("Fast typing suppresses generative flicker until typing pauses")
    func fastTypingSuppressesGenerativeFlicker() async throws {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        
        // Simulating rapid typing of an unknown custom command without local vocabulary/history
        let snap1 = CommandContextSnapshot(inputBuffer: "xyztool a")
        let snap2 = CommandContextSnapshot(inputBuffer: "xyztool ab")
        let snap3 = CommandContextSnapshot(inputBuffer: "xyztool abc")

        pipeline.request(snapshot: snap1)
        try await Task.sleep(for: .milliseconds(50))
        pipeline.request(snapshot: snap2)
        try await Task.sleep(for: .milliseconds(50))
        pipeline.request(snapshot: snap3)

        // While typing fast without local history, suggestion is immediately nil or delayed
        #expect(pipeline.suggestion == nil)
    }

    @Test("Middle-of-token cursor suppresses generative query")
    func middleOfTokenSuppressesGenerative() {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        
        // Cursor placed inside 'dock|er'
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker ps",
            cursorOffset: 4
        )

        pipeline.request(snapshot: snapshot)

        // Pipeline should not request LLM when editing mid-token
        #expect(pipeline.isRequesting == false)
    }

    @Test("Rejection prevents candidate from resurfacing in subsequent requests")
    func rejectionPreventsGhostResurfacing() {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker",
            recentCommands: ["docker ps -a"],
            recentOutput: ""
        )

        pipeline.request(snapshot: snapshot)
        #expect(pipeline.suggestion != nil)
        let firstSuggestion = pipeline.suggestion?.text

        pipeline.rejectCurrent()
        #expect(pipeline.suggestion == nil)

        // Subsequent request for same prefix must not show the rejected suggestion
        pipeline.request(snapshot: snapshot)
        #expect(pipeline.suggestion?.text != firstSuggestion)
    }

    @Test("Conversational text from LLM adapter is rejected silently without corrupting terminal")
    func conversationalTextRejectedSilently() {
        let adapted = LLMCompletionAdapter.adapt(
            rawOutput: "Sure! To list all running containers, you can use: docker ps",
            typed: "dock"
        )
        #expect(adapted == nil)
    }

    @Test("Reasoning tags from LLM adapter are completely stripped")
    func reasoningTagsStrippedByAdapter() {
        let raw = "<think>The user wants to run redis in detached mode</think> docker run -d redis"
        let adapted = LLMCompletionAdapter.adapt(rawOutput: raw, typed: "docker")
        #expect(adapted?.text == " run -d redis")
    }
}
