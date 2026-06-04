//
//  OSC7DetectorTests.swift
//  BonkTests
//

import XCTest
@testable import Bonk

final class OSC7DetectorTests: XCTestCase {

    func testDetectsSimplePath() {
        let detector = PTYOSC7Detector()
        var detectedPath: String?
        detector.onCWDChange = { detectedPath = $0 }

        // OSC 7: ESC ] 7 ; file://host/path BEL
        detector.process("\u{1B}]7;file://localhost/home/user\u{07}")
        XCTAssertEqual(detectedPath, "/home/user")
    }

    func testDetectsPathWithoutHost() {
        let detector = PTYOSC7Detector()
        var detectedPath: String?
        detector.onCWDChange = { detectedPath = $0 }

        detector.process("\u{1B}]7;file:///tmp/workdir\u{07}")
        XCTAssertEqual(detectedPath, "/tmp/workdir")
    }

    func testIgnoresNonFileURL() {
        let detector = PTYOSC7Detector()
        var detected = false
        detector.onCWDChange = { _ in detected = true }

        detector.process("\u{1B}]7;https://example.com\u{07}")
        XCTAssertFalse(detected)
    }

    func testMultipleSequences() {
        let detector = PTYOSC7Detector()
        var paths: [String] = []
        detector.onCWDChange = { paths.append($0) }

        detector.process("\u{1B}]7;file:///a\u{07}text\u{1B}]7;file:///b\u{07}")
        XCTAssertEqual(paths, ["/a", "/b"])
    }

    func testPartialSequenceAcrossCalls() {
        let detector = PTYOSC7Detector()
        var detectedPath: String?
        detector.onCWDChange = { detectedPath = $0 }

        detector.process("\u{1B}]7;file://")
        detector.process("localhost/home\u{07}")
        XCTAssertEqual(detectedPath, "/home")
    }

    func testSTTerminator() {
        let detector = PTYOSC7Detector()
        var detectedPath: String?
        detector.onCWDChange = { detectedPath = $0 }

        // ST terminator: ESC \
        detector.process("\u{1B}]7;file:///tmp\u{1B}\\")
        XCTAssertEqual(detectedPath, "/tmp")
    }

    func testPlainTextIgnored() {
        let detector = PTYOSC7Detector()
        var detected = false
        detector.onCWDChange = { _ in detected = true }

        detector.process("just plain text\nno escape sequences")
        XCTAssertFalse(detected)
    }
}
