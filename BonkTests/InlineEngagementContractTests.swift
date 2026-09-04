//
//  InlineEngagementContractTests.swift
//  BonkTests
//
//  P0.1 Inline Completion State Machine & Engagement Contract Tests.
//

import Testing
import Foundation
@testable import Bonk

@Suite("P0.1 Inline Completion Engagement Contract Tests")
@MainActor
struct InlineEngagementContractTests {

    private func makePipelineWithCandidates() -> InlineSuggestionPipeline {
        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        let snapshot = CommandContextSnapshot(
            inputBuffer: "dock",
            recentCommands: ["docker ps", "docker build -t app .", "docker-compose up"],
            recentOutput: ""
        )
        pipeline.request(snapshot: snapshot)
        return pipeline
    }

    @Test("1. Initial state is passive and selectedIndex is nil")
    func testInitialStateIsPassive() {
        let pipeline = makePipelineWithCandidates()
        #expect(!pipeline.ranked.isEmpty)
        #expect(pipeline.engagement == .passive)
        #expect(pipeline.selectedIndex == nil)
        // In passive state, recommendation is still visible for Tab completion
        #expect(pipeline.suggestion != nil)
    }

    @Test("2. Passive + Enter guarantees Shell passthrough without hijacking")
    func testPassiveEnterPassesThroughToShell() {
        let pipeline = makePipelineWithCandidates()
        #expect(pipeline.engagement == .passive)

        // In Passive state:
        // hasSuggestion is true, but engagement.isEngaged is false.
        // The contract dictates: Enter must NOT accept the candidate, but cancel and forward to shell.
        #expect(!pipeline.engagement.isEngaged)

        // Emulate Enter key handling in NativeTerminalView
        let shouldHijackForCandidate = pipeline.suggestion != nil && pipeline.engagement.isEngaged
        #expect(!shouldHijackForCandidate)

        // Shell gets the input buffer as-is; pipeline is cancelled
        pipeline.cancel()
        #expect(pipeline.suggestion == nil)
        #expect(pipeline.engagement == .passive)
    }

    @Test("3. Passive + Tab accepts top recommended candidate")
    func testPassiveTabAcceptsCandidate() {
        let pipeline = makePipelineWithCandidates()
        #expect(pipeline.engagement == .passive)
        let topCandidate = pipeline.ranked.first?.1

        // In passive mode, pipeline.suggestion gives the top recommended candidate
        #expect(pipeline.suggestion?.text == topCandidate?.text)

        let accepted = pipeline.accept()
        #expect(accepted == topCandidate?.text)
        #expect(pipeline.suggestion == nil)
    }

    @Test("4. Passive + ↓ engages keyboard selection at index 0")
    func testArrowDownEngagesSelection() {
        let pipeline = makePipelineWithCandidates()
        #expect(pipeline.engagement == .passive)

        pipeline.moveSelection(1)
        #expect(pipeline.engagement == .engaged(index: 0))
        #expect(pipeline.selectedIndex == 0)
        #expect(pipeline.engagement.isEngaged)
        #expect(pipeline.suggestion?.text == pipeline.ranked[0].1.text)
    }

    @Test("5. Passive + ↑ engages keyboard selection at last candidate")
    func testArrowUpEngagesSelection() {
        let pipeline = makePipelineWithCandidates()
        #expect(pipeline.engagement == .passive)
        let lastIndex = pipeline.ranked.count - 1

        pipeline.moveSelection(-1)
        #expect(pipeline.engagement == .engaged(index: lastIndex))
        #expect(pipeline.selectedIndex == lastIndex)
        #expect(pipeline.engagement.isEngaged)
        #expect(pipeline.suggestion?.text == pipeline.ranked[lastIndex].1.text)
    }

    @Test("6. Engaged + Enter accepts candidate")
    func testEngagedEnterAcceptsCandidate() {
        let pipeline = makePipelineWithCandidates()
        // Move selection to candidate 1
        pipeline.moveSelection(1) // engages at 0
        pipeline.moveSelection(1) // moves to 1
        #expect(pipeline.selectedIndex == 1)
        let selectedCandidate = pipeline.ranked[1].1

        let shouldHijackForCandidate = pipeline.suggestion != nil && pipeline.engagement.isEngaged
        #expect(shouldHijackForCandidate)

        let accepted = pipeline.accept()
        #expect(accepted == selectedCandidate.text)
        #expect(pipeline.suggestion == nil)
    }

    @Test("7. Engaged + Tab accepts candidate")
    func testEngagedTabAcceptsCandidate() {
        let pipeline = makePipelineWithCandidates()
        pipeline.moveSelection(1) // engages at 0
        pipeline.moveSelection(1) // moves to 1
        #expect(pipeline.selectedIndex == 1)
        let selectedCandidate = pipeline.ranked[1].1

        let accepted = pipeline.accept()
        #expect(accepted == selectedCandidate.text)
        #expect(pipeline.suggestion == nil)
    }

    @Test("8. Editing / Typing / Backspace leaves engaged state back to passive")
    func testEditingLeavesEngagedState() {
        let pipeline = makePipelineWithCandidates()
        pipeline.moveSelection(1)
        #expect(pipeline.engagement.isEngaged)

        pipeline.resetEngagement()
        #expect(pipeline.engagement == .passive)
        #expect(pipeline.selectedIndex == nil)

        // New request also starts in passive
        let newSnapshot = CommandContextSnapshot(inputBuffer: "docker p", recentCommands: [], recentOutput: "")
        pipeline.request(snapshot: newSnapshot)
        #expect(pipeline.engagement == .passive)
        #expect(pipeline.selectedIndex == nil)
    }

    @Test("9. Escape cancels selection and marks suggestion rejected")
    func testEscapeCancelsSelection() {
        let pipeline = makePipelineWithCandidates()
        pipeline.moveSelection(1) // engaged
        #expect(pipeline.suggestion != nil)

        pipeline.rejectCurrent()
        #expect(pipeline.suggestion == nil)
        #expect(pipeline.engagement == .passive)
        #expect(pipeline.selectedIndex == nil)
    }
}
