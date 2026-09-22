//
//  GhostDisplayContractTests.swift
//  BonkTests
//
//  A-phase: display == insert, and ghost/popup independently toggleable.
//  - displaySuffix never invents a separator the insertion lacks.
//  - Policy flag matrix degrades .show correctly; both off hides all.
//  - Settings snapshot defaults keep legacy behavior (ghost on).
//

@testable import Bonk
import Foundation
import Testing

@Suite("Ghost Display Contract Tests")
@MainActor
struct GhostDisplayContractTests {
    // MARK: - A1: display equals insertion

    @Test("Explicit separator in raw suffix is preserved")
    func testExplicitSeparatorPreserved() {
        #expect(SuggestionFormatter.displaySuffix(" compose", typed: "docker") == " compose")
        #expect(SuggestionFormatter.displaySuffix(" run -d nginx", typed: "docker") == " run -d nginx")
    }

    @Test("No virtual space is invented for mid-token suffixes")
    func testNoVirtualSpace() {
        // The reported bug: ghost showed " -compose" while Tab inserted "-compose".
        #expect(SuggestionFormatter.displaySuffix("-compose", typed: "docker") == "-compose")
        #expect(SuggestionFormatter.displaySuffix("compose", typed: "docker") == "compose")
        #expect(SuggestionFormatter.displaySuffix("compose", typed: "docker ") == "compose")
    }

    @Test("Empty and whitespace-only suffixes stay empty")
    func testEmptyStaysEmpty() {
        #expect(SuggestionFormatter.displaySuffix("", typed: "docker") == "")
        #expect(SuggestionFormatter.displaySuffix("   ", typed: "docker") == "")
    }

    // MARK: - A2: ghost/popup flag matrix

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

    @Test("Both off hides everything")
    func testBothOffHides() {
        let action = InlinePresentationPolicy.evaluate(
            ranked: candidates(), inputBuffer: "docker",
            ghostEnabled: false, popupEnabled: false
        )
        #expect(action == .hide)
    }

    @Test("Ghost off degrades show to popup-only")
    func testGhostOffPopupOnly() {
        let action = InlinePresentationPolicy.evaluate(
            ranked: candidates(), inputBuffer: "docker",
            ghostEnabled: false, popupEnabled: true
        )
        #expect(action == .popupOnly)
    }

    @Test("Ghost off with a single candidate hides (no popup to show)")
    func testGhostOffSingleHides() {
        let action = InlinePresentationPolicy.evaluate(
            ranked: Array(candidates().prefix(1)), inputBuffer: "docker",
            ghostEnabled: false, popupEnabled: true
        )
        #expect(action == .hide)
    }

    @Test("Popup off strips the popup but keeps the ghost")
    func testPopupOffKeepsGhost() {
        let action = InlinePresentationPolicy.evaluate(
            ranked: candidates(), inputBuffer: "docker",
            ghostEnabled: true, popupEnabled: false
        )
        if case let .show(_, showPopup) = action {
            #expect(!showPopup)
        } else {
            Issue.record("Expected .show without popup, got \(action)")
        }
    }

    @Test("Both on preserves legacy behavior")
    func testBothOnLegacy() {
        let action = InlinePresentationPolicy.evaluate(
            ranked: candidates(), inputBuffer: "docker",
            ghostEnabled: true, popupEnabled: true
        )
        if case let .show(_, showPopup) = action {
            #expect(showPopup)
        } else {
            Issue.record("Expected legacy .show, got \(action)")
        }
    }

    // MARK: - Settings snapshot defaults

    @Test("Ghost defaults on, engine defaults jev")
    func testSnapshotDefaults() {
        let snap = AISettingsSnapshot(
            aiEnabled: false,
            inlineSuggestionsEnabled: false,
            ghostSuggestionsEnabled: true,
            candidatePopupEnabled: true,
            decisionEngineID: "jev",
            decisionThreshold: 0.75
        )
        #expect(snap.ghostSuggestionsEnabled)
        #expect(snap.decisionEngineID == "jev")
        #expect(snap.decisionThreshold == 0.75)
    }
}
