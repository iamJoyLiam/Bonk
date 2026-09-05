//  InlinePresentationPolicyContractTests.swift
//  BonkTests
//
//  Contract tests for InlinePresentationPolicy (P0.4).
//  Guarantees presentation gating rules for deterministic vs generative candidates.
//

import Testing
@testable import Bonk

@Suite("InlinePresentationPolicy Contract Tests")
struct InlinePresentationPolicyContractTests {

    @Test("Deterministic candidate is always shown immediately even with 1 character and fast typing")
    func deterministicCandidateAlwaysShownImmediately() {
        let candidate = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: "git status", displayText: "status"),
            rawScore: 90.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [candidate],
            inputBuffer: "g",
            isTypingFast: true
        )
        #expect(action == .show(suggestion: candidate.suggestion, showPopup: false))
    }

    @Test("Deterministic candidate sets showPopup = true when multiple candidates exist")
    func deterministicMultipleCandidatesShowPopup() {
        let c1 = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: "git status", displayText: "status"),
            rawScore: 90.0
        )
        let c2 = CommandCandidate(
            source: "vocabulary",
            authority: .deterministic,
            suggestion: Suggestion(text: "git switch", displayText: "switch"),
            rawScore: 80.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [c1, c2],
            inputBuffer: "git s",
            isTypingFast: false
        )
        #expect(action == .show(suggestion: c1.suggestion, showPopup: true))
    }

    @Test("Contextual candidate is shown immediately even when typing fast")
    func contextualCandidateAlwaysShownImmediately() {
        let candidate = CommandCandidate(
            source: "cwd_files",
            authority: .contextual,
            suggestion: Suggestion(text: "cat README.md", displayText: "README.md"),
            rawScore: 85.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [candidate],
            inputBuffer: "cat R",
            isTypingFast: true
        )
        #expect(action == .show(suggestion: candidate.suggestion, showPopup: false))
    }

    @Test("Generative candidate is hidden when input is shorter than minGenerativeStandaloneChars")
    func generativeCandidateHiddenWhenInputTooShort() {
        let candidate = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: "docker ps", displayText: "cker ps"),
            rawScore: 70.0
        )
        // inputBuffer "do" has length 2, which is < 3
        let action = InlinePresentationPolicy.evaluate(
            ranked: [candidate],
            inputBuffer: "do",
            isTypingFast: false
        )
        #expect(action == .hide)
    }

    @Test("Generative candidate is delayed when user is typing fast")
    func generativeCandidateDelayedWhenTypingFast() {
        let candidate = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: "docker compose up", displayText: "compose up"),
            rawScore: 70.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [candidate],
            inputBuffer: "docker ",
            isTypingFast: true
        )
        #expect(action == .delay(ms: 120))
    }

    @Test("Generative candidate is shown when input is sufficient and not typing fast")
    func generativeCandidateShownWhenInputSufficientAndNotFast() {
        let candidate = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: "docker run -d redis", displayText: "run -d redis"),
            rawScore: 70.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [candidate],
            inputBuffer: "docker ",
            isTypingFast: false
        )
        #expect(action == .show(suggestion: candidate.suggestion, showPopup: false))
    }

    @Test("Generative candidate sets showPopup = true when multiple candidates exist")
    func generativeCandidatePopupFlagWhenMultipleCandidates() {
        let c1 = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: "docker run", displayText: "run"),
            rawScore: 70.0
        )
        let c2 = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: "docker rm", displayText: "rm"),
            rawScore: 60.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [c1, c2],
            inputBuffer: "docker ",
            isTypingFast: false
        )
        #expect(action == .show(suggestion: c1.suggestion, showPopup: true))
    }

    @Test("Empty ranked candidates list returns hide")
    func emptyCandidatesListReturnsHide() {
        let action = InlinePresentationPolicy.evaluate(
            ranked: [],
            inputBuffer: "echo test",
            isTypingFast: false
        )
        #expect(action == .hide)
    }

    @Test("Candidate with empty suggestion text returns hide")
    func emptySuggestionTextReturnsHide() {
        let candidate = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: "", displayText: ""),
            rawScore: 50.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [candidate],
            inputBuffer: "echo test",
            isTypingFast: false
        )
        #expect(action == .hide)
    }

    @Test("Single character with multiple candidates delays 350ms when typing fast")
    func singleCharMultipleCandidatesDelays350msWhenTypingFast() {
        let c1 = CommandCandidate(
            source: "vocabulary",
            authority: .deterministic,
            suggestion: Suggestion(text: "ocker", displayText: "ocker", fullText: "docker"),
            rawScore: 80.0
        )
        let c2 = CommandCandidate(
            source: "vocabulary",
            authority: .deterministic,
            suggestion: Suggestion(text: "f", displayText: "f", fullText: "df"),
            rawScore: 78.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [c1, c2],
            inputBuffer: "d",
            isTypingFast: true
        )
        #expect(action == .delay(ms: 350))
    }

    @Test("Single character with multiple candidates shows popup immediately when not typing fast")
    func singleCharMultipleCandidatesShowsImmediatelyWhenNotFast() {
        let c1 = CommandCandidate(
            source: "vocabulary",
            authority: .deterministic,
            suggestion: Suggestion(text: "ocker", displayText: "ocker", fullText: "docker"),
            rawScore: 80.0
        )
        let c2 = CommandCandidate(
            source: "vocabulary",
            authority: .deterministic,
            suggestion: Suggestion(text: "f", displayText: "f", fullText: "df"),
            rawScore: 78.0
        )
        let action = InlinePresentationPolicy.evaluate(
            ranked: [c1, c2],
            inputBuffer: "d",
            isTypingFast: false
        )
        #expect(action == .show(suggestion: c1.suggestion, showPopup: true))
    }
}
