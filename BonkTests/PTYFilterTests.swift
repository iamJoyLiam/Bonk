//
//  PTYFilterTests.swift
//  BonkTests
//

import XCTest
@testable import Bonk

final class PTYFilterTests: XCTestCase {

    typealias Filter = PTYSession

    func testPlainTextPassThrough() {
        let input = "hello world"
        XCTAssertEqual(Filter.filterOSCSequences(input), input)
    }

    func testEmptyString() {
        XCTAssertEqual(Filter.filterOSCSequences(""), "")
    }

    func testOSCSequenceStripped() {
        // OSC: ESC ] ... BEL
        let input = "\u{1B}]0;title\u{07}hello"
        let result = Filter.filterOSCSequences(input)
        XCTAssertEqual(result, "hello")
    }

    func testDCSSequenceStripped() {
        // DCS: ESC P ... ESC \
        let input = "before\u{1B}Pqstuff\u{1B}\\after"
        let result = Filter.filterOSCSequences(input)
        XCTAssertEqual(result, "beforeafter")
    }

    func testCSISequencePreserved() {
        // CSI: ESC [ ... letter (color codes, cursor movement)
        let input = "\u{1B}[31mred\u{1B}[0m"
        let result = Filter.filterOSCSequences(input)
        XCTAssertEqual(result, input)
    }

    func testCharsetSelectorPreserved() {
        // ESC ( 0, ESC ) B — charset selectors
        let input = "\u{1B}(0\u{1B})B"
        let result = Filter.filterOSCSequences(input)
        XCTAssertEqual(result, input)
    }

    func testMixedSequences() {
        let input = "start\u{1B}[1mbold\u{1B}[0m\u{1B}]0;title\u{07}end"
        let result = Filter.filterOSCSequences(input)
        XCTAssertEqual(result, "start\u{1B}[1mbold\u{1B}[0mend")
    }

    func testMultipleOSCInOneString() {
        let input = "\u{1B}]0;a\u{07}mid\u{1B}]0;b\u{07}"
        let result = Filter.filterOSCSequences(input)
        XCTAssertEqual(result, "mid")
    }

    func testOSCWithBELTerminator() {
        let input = "\u{1B}]4;1;rgb:ff/00/00\u{07}"
        let result = Filter.filterOSCSequences(input)
        XCTAssertEqual(result, "")
    }

    // MARK: - Shell integration OSC 133;9 buffer report parsing

    private func collectReports(_ text: String) -> [String] {
        let integration = ShellIntegration()
        var reports: [String] = []
        integration.onEvent = { event in
            if case .bufferReport(let buffer) = event { reports.append(buffer) }
        }
        _ = integration.process(text: text, lineCount: 1)
        return reports
    }

    func testBufferReportBELTerminator() {
        XCTAssertEqual(collectReports("\u{1B}]133;9;docker ps\u{07}"), ["docker ps"])
    }

    func testBufferReportSTTerminator() {
        // ST terminator (ESC \) — what the zsh snippet emits via printf
        XCTAssertEqual(collectReports("\u{1B}]133;9;echo a;b\u{1B}\\"), ["echo a;b"])
    }

    func testBufferReportEmptyBuffer() {
        XCTAssertEqual(collectReports("\u{1B}]133;9;\u{07}"), [""])
    }

    func testBufferReportDoesNotEmitOther133Events() {
        // A bare 9-report must not be mistaken for A/B/C/D prompt events
        let integration = ShellIntegration()
        let events = integration.process(text: "\u{1B}]133;9;ls\u{07}", lineCount: 1)
        XCTAssertEqual(events.count, 1)
        if case .bufferReport = events[0] {} else {
            XCTFail("expected bufferReport, got \(events[0])")
        }
    }
}
