//
//  CursorAnchorContractTests.swift
//  BonkTests
//
//  B-phase: cursor-coordinate invariant for inline suggestions.
//  - CursorContext resolves prefix/suffix/end/token from one place.
//  - Ghost hides on known mid-line cursor; the popup continues.
//  - Passive-ghost accept verifies the anchor; engaged popup bypasses it.
//

@testable import Bonk
import Foundation
import Testing

@Suite("Cursor Anchor Contract Tests")
@MainActor
struct CursorAnchorContractTests {
    // MARK: - CursorContext (minimal: end-state + anchor check only)

    @Test("End offset resolves to line end")
    func testEndOffset() {
        let ctx = CursorContext.resolve(buffer: "docker", cursorOffset: 6)
        #expect(ctx.isAtLineEnd)
        #expect(ctx.isCursorKnown)
    }

    @Test("Mid-line offset is not at line end")
    func testMidLineOffset() {
        let ctx = CursorContext.resolve(buffer: "docker", cursorOffset: 2)
        #expect(!ctx.isAtLineEnd)
        #expect(ctx.isCursorKnown)
    }

    @Test("Unknown cursor assumes end but flags unknown")
    func testUnknownCursor() {
        let ctx = CursorContext.resolve(buffer: "docker", cursorOffset: nil)
        #expect(ctx.isAtLineEnd)
        #expect(!ctx.isCursorKnown)
    }

    @Test("Out-of-range offsets clamp to line end")
    func testClampedOffset() {
        let ctx = CursorContext.resolve(buffer: "docker", cursorOffset: 99)
        #expect(ctx.isAtLineEnd)
    }

    @Test("Anchor allows appends, rejects mid-line edits and deletions")
    func testAnchorAllowsInsert() {
        #expect(CursorContext.anchorAllowsInsert(anchorBuffer: "dock", currentBuffer: "docker"))
        #expect(CursorContext.anchorAllowsInsert(anchorBuffer: "docker", currentBuffer: "docker"))
        #expect(!CursorContext.anchorAllowsInsert(anchorBuffer: "docker", currentBuffer: "dock"))
        #expect(!CursorContext.anchorAllowsInsert(anchorBuffer: "docker", currentBuffer: "dockXer"))
        #expect(!CursorContext.anchorAllowsInsert(anchorBuffer: "docker", currentBuffer: "sudo docker"))
    }

    // MARK: - Presentation: ghost hides mid-line, popup continues

    private func candidates() -> [CommandCandidate] {
        [
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " ps", displayText: " ps", fullText: "docker ps"),
                rawScore: 90.0
            ),
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: " images", displayText: " images", fullText: "docker images"),
                rawScore: 80.0
            ),
        ]
    }

    @Test("Known mid-line cursor suppresses ghost but keeps popup")
    func testMidLinePopupOnly() {
        let cursor = CursorContext.resolve(buffer: "docker", cursorOffset: 2)
        let action = InlinePresentationPolicy.evaluate(
            ranked: candidates(), inputBuffer: "docker", cursor: cursor
        )
        #expect(action == .popupOnly)
    }

    @Test("Known mid-line cursor with a single candidate hides everything")
    func testMidLineSingleHides() {
        let cursor = CursorContext.resolve(buffer: "docker", cursorOffset: 2)
        let action = InlinePresentationPolicy.evaluate(
            ranked: Array(candidates().prefix(1)), inputBuffer: "docker", cursor: cursor
        )
        #expect(action == .hide)
    }

    @Test("Unknown cursor preserves legacy ghost behavior")
    func testUnknownCursorLegacyGhost() {
        let action = InlinePresentationPolicy.evaluate(
            ranked: candidates(), inputBuffer: "docker", cursor: nil
        )
        if case let .show(_, showPopup) = action {
            #expect(showPopup)
        } else {
            Issue.record("Expected .show for unknown cursor, got \(action)")
        }
    }

    // MARK: - Pipeline anchor record + accept defense

    private func pipelineWithGhost() -> InlineSuggestionPipeline {
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: InlineSuggestionCache())
        pipeline.request(snapshot: CommandContextSnapshot(
            inputBuffer: "docker",
            recentCommands: ["docker ps", "docker images"],
            recentOutput: ""
        ))
        return pipeline
    }

    @Test("Shown suggestion records its anchor")
    func testAnchorRecorded() {
        let pipeline = pipelineWithGhost()
        #expect(pipeline.suggestion != nil)
        #expect(pipeline.suggestionAnchor?.typed == "docker")
    }

    @Test("Accept proceeds when the buffer only appended at end")
    func testAcceptAppend() {
        let pipeline = pipelineWithGhost()
        let text = pipeline.accept(currentTyped: "docker", currentAtLineEnd: true)
        #expect(!text.isEmpty)
    }

    @Test("Accept rejects mid-line edits and moved cursors")
    func testAcceptRejectsStaleAnchor() {
        let edited = pipelineWithGhost()
        #expect(edited.accept(currentTyped: "dockXer", currentAtLineEnd: true) == "")

        let moved = pipelineWithGhost()
        #expect(moved.accept(currentTyped: "docker", currentAtLineEnd: false) == "")

        let deleted = pipelineWithGhost()
        #expect(deleted.accept(currentTyped: "dock", currentAtLineEnd: true) == "")
    }

    @Test("Engaged popup selection bypasses the anchor defense")
    func testEngagedBypassesAnchor() {
        let pipeline = pipelineWithGhost()
        guard pipeline.ranked.count > 1 else {
            Issue.record("Expected multiple candidates for engagement test")
            return
        }
        pipeline.moveSelection(1)
        // Explicit user choice: inserts even though the anchor is stale.
        let text = pipeline.accept(currentTyped: "something-else", currentAtLineEnd: false)
        #expect(!text.isEmpty)
    }

    // MARK: - Engine switch clears stale suggestions
    @Test("Switching engines clears the previous engine's anchor")
    func testEngineSwitchCancels() {
        final class EngineBox: @unchecked Sendable { var id = "local" }
        let box = EngineBox()
        let pipeline = InlineSuggestionPipeline(
            providerStore: .shared,
            cache: InlineSuggestionCache(),
            engineIDProvider: { box.id }
        )
        pipeline.request(snapshot: CommandContextSnapshot(
            inputBuffer: "docker",
            recentCommands: ["docker ps", "docker images"],
            recentOutput: ""
        ))
        #expect(pipeline.suggestionAnchor?.typed == "docker")

        // Switch engines, then request something with no candidates: without
        // switch-cancel the old "docker" anchor would survive the hide.
        box.id = "laya"
        pipeline.request(snapshot: CommandContextSnapshot(
            inputBuffer: "zzzqqq",
            recentCommands: ["docker ps"],
            recentOutput: ""
        ))
        #expect(pipeline.suggestion == nil)
        #expect(pipeline.suggestionAnchor == nil)
    }

    // MARK: - Decision error messages are human-readable

    @Test("Decision errors describe the fix, not the case index")
    func testDecisionErrorMessages() {
        #expect(DecisionEngineError.missingAPIKey.localizedDescription.contains("API key"))
        #expect(DecisionEngineError.httpError(401).localizedDescription.contains("401"))
        #expect(DecisionEngineError.unhealthy("x").localizedDescription.contains("running"))
    }
}
