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

    // MARK: - Test 7: Balance channels returns all local candidates when no AI present
    func testBalanceChannelsPureLocal() {
        let locals = (1...6).map { i in
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: "cmd\(i)", displayText: "cmd\(i)"),
                rawScore: Double(100 - i)
            )
        }
        let balanced = CandidateRanker.balanceChannels(ranked: locals, totalLimit: 5, maxAICandidates: 1)
        XCTAssertEqual(balanced.count, 5)
        XCTAssertEqual(balanced.map { $0.suggestion.text }, ["cmd1", "cmd2", "cmd3", "cmd4", "cmd5"])
    }

    // MARK: - Test 8: Balance channels returns all AI candidates when no local present (pure AI / # mode)
    func testBalanceChannelsPureAI() {
        let aiCandidates = [
            CommandCandidate(
                source: "llm",
                authority: .generative,
                suggestion: Suggestion(text: "docker ps", displayText: "docker ps"),
                rawScore: 99.0
            ),
            CommandCandidate(
                source: "llm",
                authority: .generative,
                suggestion: Suggestion(text: "docker container ls", displayText: "docker container ls"),
                rawScore: 90.0
            )
        ]
        let balanced = CandidateRanker.balanceChannels(ranked: aiCandidates, totalLimit: 5, maxAICandidates: 1)
        XCTAssertEqual(balanced.count, 2)
        XCTAssertEqual(balanced[0].suggestion.text, "docker ps")
        XCTAssertEqual(balanced[1].suggestion.text, "docker container ls")
    }

    // MARK: - Test 9: Mixed mode strictly limits AI to 1 slot and preserves local top 4
    func testBalanceChannelsMixedEnforcesRatioAndPreventsDisplacement() {
        let locals = (1...5).map { i in
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: "local\(i)", displayText: "local\(i)"),
                rawScore: Double(100 - i)
            )
        }
        let aiCandidates = [
            CommandCandidate(
                source: "llm",
                authority: .generative,
                suggestion: Suggestion(text: "ai1", displayText: "ai1"),
                rawScore: 99.0
            ),
            CommandCandidate(
                source: "llm",
                authority: .generative,
                suggestion: Suggestion(text: "ai2", displayText: "ai2"),
                rawScore: 95.0
            )
        ]
        // Mix them together:
        let combined = aiCandidates + locals
        let balanced = CandidateRanker.balanceChannels(ranked: combined, totalLimit: 5, maxAICandidates: 1)

        XCTAssertEqual(balanced.count, 5)
        // First 4 must be local 1..4 (order preserved, preventing layout jump)
        XCTAssertEqual(balanced[0].suggestion.text, "local1")
        XCTAssertEqual(balanced[1].suggestion.text, "local2")
        XCTAssertEqual(balanced[2].suggestion.text, "local3")
        XCTAssertEqual(balanced[3].suggestion.text, "local4")
        // 5th must be the highest AI candidate
        XCTAssertEqual(balanced[4].suggestion.text, "ai1")
    }

    // MARK: - Test 10: Mixed mode with few local candidates preserves all local and takes AI
    func testBalanceChannelsMixedWithFewLocal() {
        let locals = [
            CommandCandidate(
                source: "history",
                authority: .deterministic,
                suggestion: Suggestion(text: "local1", displayText: "local1"),
                rawScore: 90.0
            ),
            CommandCandidate(
                source: "vocabulary",
                authority: .deterministic,
                suggestion: Suggestion(text: "local2", displayText: "local2"),
                rawScore: 80.0
            )
        ]
        let aiCandidates = [
            CommandCandidate(
                source: "llm",
                authority: .generative,
                suggestion: Suggestion(text: "ai1", displayText: "ai1"),
                rawScore: 99.0
            ),
            CommandCandidate(
                source: "llm",
                authority: .generative,
                suggestion: Suggestion(text: "ai2", displayText: "ai2"),
                rawScore: 95.0
            )
        ]
        let balanced = CandidateRanker.balanceChannels(ranked: locals + aiCandidates, totalLimit: 5, maxAICandidates: 1)
        XCTAssertEqual(balanced.count, 3)
        XCTAssertEqual(balanced[0].suggestion.text, "local1")
        XCTAssertEqual(balanced[1].suggestion.text, "local2")
        XCTAssertEqual(balanced[2].suggestion.text, "ai1")
    }
}
