//
//  InlineCandidateTests.swift
//  BonkTests
//
//  Parity: new CandidateSources must match legacy InlineCompletionService/SuggestionEngine logic.
//

@testable import Bonk
import XCTest

final class InlineCandidateTests: XCTestCase {
    // MARK: - HistoryCandidateSource

    func testHistoryMatchesMostRecent() {
        let snap = CommandContextSnapshot(
            inputBuffer: "docker",
            recentCommands: ["cd /tmp", "docker ps", "docker run -d nginx"],
            recentOutput: ""
        )
        let source = HistoryCandidateSource()
        let exp = expectation(description: "history")
        Task {
            let sug = await source.suggestion(for: snap, typed: "docker")
            XCTAssertEqual(sug?.text, " run -d nginx")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testHistoryEmptyWithoutMatch() {
        let snap = CommandContextSnapshot(inputBuffer: "git", recentCommands: ["cd /tmp"], recentOutput: "")
        let source = HistoryCandidateSource()
        let exp = expectation(description: "empty")
        Task {
            let sug = await source.suggestion(for: snap, typed: "git")
            XCTAssertNil(sug)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testHistoryParityWithLegacyLocalSuggestion() {
        let history = ["docker run -d --name web nginx", "ls -la"]
        let typed = "docker run"
        let snap = CommandContextSnapshot(inputBuffer: typed, recentCommands: history, recentOutput: "")
        let source = HistoryCandidateSource()
        let exp = expectation(description: "parity")
        Task {
            let sug = await source.suggestion(for: snap, typed: typed)
            let expected = " -d --name web nginx"
            XCTAssertEqual(sug?.text, expected)
            XCTAssertEqual(sug?.displayText, SuggestionFormatter.displaySuffix(expected, typed: typed))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - KnownWordsCandidateSource

    func testKnownWordsCompletesLastToken() {
        let snap = CommandContextSnapshot(
            inputBuffer: "docker logs con",
            recentOutput: "container web_1 running",
            knownWords: ["container", "web_1", "web_2"]
        )
        let source = KnownWordsCandidateSource()
        let exp = expectation(description: "knownWords")
        Task {
            let sug = await source.suggestion(for: snap, typed: "docker logs con")
            // last token "con" -> "container" => suffix "tainer"
            XCTAssertEqual(sug?.text, "tainer")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testKnownWordsSortedPicksShortest() {
        let snap = CommandContextSnapshot(
            inputBuffer: "x a",
            knownWords: ["abcd", "ab", "abcde"]
        )
        let source = SortedKnownWordsCandidateSource()
        let exp = expectation(description: "sorted")
        Task {
            let sug = await source.suggestion(for: snap, typed: "x a")
            // token "a" -> shortest match "ab" -> suffix "b"
            XCTAssertEqual(sug?.text, "b")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testCandidateSetIsEmpty() {
        let set = InlineCandidateSet(candidates: [])
        XCTAssertTrue(set.isEmpty)
    }

    func testInlineCandidateDomainProperties() {
        let candidate = InlineCandidate(
            source: .cliSpec,
            authority: .deterministic,
            text: "ps",
            displayText: "ps",
            fullText: "docker ps",
            summary: "List containers",
            score: 95.0,
            isExactPrefixMatch: true,
            metadata: CandidateMetadata(fullCommand: "docker ps", isExactPrefixMatch: true)
        )

        XCTAssertEqual(candidate.typedSource, .cliSpec)
        XCTAssertFalse(candidate.typedSource.isAI)
        XCTAssertEqual(candidate.summary, "List containers")
        XCTAssertEqual(candidate.suggestion.text, "ps")
        XCTAssertEqual(candidate.fullText, "docker ps")
        XCTAssertEqual(candidate.rawScore, 95.0)
        XCTAssertTrue(candidate.isExactPrefixMatch)
    }

    func testInlineMetricsLatency() {
        var metrics = InlineMetrics(keyPressedAt: Date(timeIntervalSince1970: 1000.0))
        metrics.markCandidateProduced()
        metrics.markRenderCompleted()

        XCTAssertNotNil(metrics.computeLatencyMs)
        XCTAssertNotNil(metrics.totalLatencyMs)
    }
}
