//  OutputGuardContractTests.swift
//  BonkTests
//
//  Contract tests for OutputGuard (P1.3).
//  Validates Head 80 + Tail 80 line preservation and 32KB byte budget limit.
//

import Testing
import Foundation
@testable import Bonk

@Suite("OutputGuard Contract Tests")
struct OutputGuardContractTests {

    @Test("Small output under budget is not truncated")
    func smallOutputNotTruncated() {
        let raw = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        let result = OutputGuard.guardOutput(raw)
        #expect(!result.isTruncated)
        #expect(result.content == raw)
        #expect(result.skippedLines == 0)
    }

    @Test("Large line count output preserves Head 80 and Tail 80 lines")
    func largeLineCountPreservesHeadAndTail() {
        let lines = (1...300).map { "Line \($0)" }
        let raw = lines.joined(separator: "\n")
        let result = OutputGuard.guardOutput(raw)

        #expect(result.isTruncated)
        #expect(result.totalLines == 300)
        #expect(result.skippedLines == 140) // 300 - 80 - 80

        #expect(result.content.contains("Line 1"))
        #expect(result.content.contains("Line 80"))
        #expect(result.content.contains("... [Output truncated: 140 lines skipped"))
        #expect(result.content.contains("Line 221"))
        #expect(result.content.contains("Line 300"))
        #expect(!result.content.contains("Line 150"))
    }

    @Test("Huge output is strictly capped under byte budget")
    func hugeOutputCappedUnderByteBudget() {
        let hugeChunk = String(repeating: "A", count: 100_000)
        let result = OutputGuard.guardOutput(hugeChunk)

        #expect(result.isTruncated)
        #expect(result.content.utf8.count <= OutputGuard.maxBytes + 200)
    }
}
