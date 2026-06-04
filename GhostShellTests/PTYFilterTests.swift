//
//  PTYFilterTests.swift
//  GhostShellTests
//

import XCTest
@testable import GhostShell

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
}
