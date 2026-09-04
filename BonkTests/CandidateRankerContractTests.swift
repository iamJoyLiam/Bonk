//
//  CandidateRankerContractTests.swift
//  BonkTests
//
//  Commit 0.1 UX Contract Tests: Candidate Authority & Ranker Boundary
//

@testable import Bonk
import XCTest

final class CandidateRankerContractTests: XCTestCase {
    // MARK: - Test 1: Local wins over LLM by Authority
    func testLocalWinsOverLLMByAuthority() {
        let localCandidate = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: " ps -a", displayText: " ps -a"),
            rawScore: 80.0
        )
        let llmCandidate = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: " run -d nginx", displayText: " run -d nginx"),
            rawScore: 80.0
        )

        let ranked = CandidateRanker.rank(candidates: [llmCandidate, localCandidate])
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].source, "history", "Deterministic candidate must rank above generative candidate")
        XCTAssertEqual(ranked[0].authority, .deterministic)
    }

    // MARK: - Test 2: Two deterministic candidates ordered by rawScore
    func testTwoDeterministicCandidatesOrderedByRawScore() {
        let candidateA = CommandCandidate(
            source: "knownWords",
            authority: .deterministic,
            suggestion: Suggestion(text: "checkout", displayText: "checkout"),
            rawScore: 95.0
        )
        let candidateB = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: "commit", displayText: "commit"),
            rawScore: 80.0
        )

        let ranked = CandidateRanker.rank(candidates: [candidateB, candidateA])
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].suggestion.text, "checkout", "Higher rawScore must win within same authority tier")
        XCTAssertEqual(ranked[1].suggestion.text, "commit")
    }

    // MARK: - Test 3: Two generative candidates ordered by rawScore
    func testTwoGenerativeCandidatesOrderedByRawScore() {
        let candidateA = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: " pull origin main", displayText: " pull origin main"),
            rawScore: 85.0
        )
        let candidateB = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: " push -f", displayText: " push -f"),
            rawScore: 60.0
        )

        let ranked = CandidateRanker.rank(candidates: [candidateB, candidateA])
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].suggestion.text, " pull origin main")
        XCTAssertEqual(ranked[1].suggestion.text, " push -f")
    }

    // MARK: - Test 4: LLM score 999 cannot outrank Deterministic score 1
    func testLLMSuperScoreCannotOutrankDeterministicLowScore() {
        let lowScoreLocal = CommandCandidate(
            source: "vocabulary",
            authority: .deterministic,
            suggestion: Suggestion(text: "status", displayText: "status"),
            rawScore: 1.0
        )
        let superScoreLLM = CommandCandidate(
            source: "llm",
            authority: .generative,
            suggestion: Suggestion(text: "status --short --branch", displayText: "status --short --branch"),
            rawScore: 999.0
        )

        let ranked = CandidateRanker.rank(candidates: [superScoreLLM, lowScoreLocal])
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked[0].source, "vocabulary", "Generative candidate with score 999 must NEVER displace deterministic candidate with score 1")
        XCTAssertEqual(ranked[0].authority, .deterministic)
        XCTAssertEqual(ranked[1].source, "llm")
    }

    // MARK: - Test 5: Candidate ID remains stable across evaluations
    func testCandidateIDRemainsStableAcrossEvaluations() {
        let run1 = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: " checkout -b feature", displayText: " checkout -b feature"),
            rawScore: 80.0
        )
        let run2 = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: " checkout -b feature", displayText: " checkout -b feature"),
            rawScore: 82.0 // Score changed slightly
        )

        XCTAssertEqual(run1.id, run2.id, "Candidate ID must be deterministic and stable across evaluations without random UUIDs")
    }

    // MARK: - Test 6: Rejected candidate is excluded by Ranker
    func testRejectedCandidateIsExcludedByRanker() {
        let candidateGood = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: " pull", displayText: " pull"),
            rawScore: 80.0
        )
        let candidateRejected = CommandCandidate(
            source: "history",
            authority: .deterministic,
            suggestion: Suggestion(text: " push --force", displayText: " push --force"),
            rawScore: 85.0
        )

        let isRejected: (String) -> Bool = { suffix in
            suffix == " push --force"
        }

        let ranked = CandidateRanker.rank(candidates: [candidateGood, candidateRejected], isRejected: isRejected)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].suggestion.text, " pull")
    }
}
