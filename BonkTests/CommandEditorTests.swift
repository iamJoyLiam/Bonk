//
//  CommandEditorTests.swift
//  BonkTests
//

@testable import Bonk
import XCTest

final class CommandEditorTests: XCTestCase {
    func testShouldTriggerForKey() {
        XCTAssertFalse(CommandEditor.shouldTriggerForKey(keyCode: 53, modifiers: [], characters: "a")) // Esc
        XCTAssertFalse(CommandEditor.shouldTriggerForKey(keyCode: 8, modifiers: .command, characters: "a"))
        XCTAssertTrue(CommandEditor.shouldTriggerForKey(keyCode: 51, modifiers: [], characters: nil)) // delete
        XCTAssertTrue(CommandEditor.shouldTriggerForKey(keyCode: 0, modifiers: [], characters: "a"))
        XCTAssertFalse(CommandEditor.shouldTriggerForKey(keyCode: 0, modifiers: [], characters: ""))
        XCTAssertFalse(CommandEditor.shouldTriggerForKey(keyCode: 0, modifiers: [], characters: nil))
    }

    func testIsCompletableAtBottom() {
        XCTAssertTrue(CommandEditor.isCompletable(cursorX: 10, cursorY: 5, rows: 10, yDisp: 0, scrollPosition: 1.0, isAlternate: false, lineTrimmedLength: 10, isPromptRow: nil))
        XCTAssertFalse(CommandEditor.isCompletable(cursorX: 10, cursorY: 5, rows: 10, yDisp: 5, scrollPosition: 0.5, isAlternate: false, lineTrimmedLength: 10, isPromptRow: false))
        XCTAssertFalse(CommandEditor.isCompletable(cursorX: 10, cursorY: 5, rows: 10, yDisp: 0, scrollPosition: 1.0, isAlternate: true, lineTrimmedLength: 10, isPromptRow: nil))
        XCTAssertFalse(CommandEditor.isCompletable(cursorX: 0, cursorY: 5, rows: 10, yDisp: 0, scrollPosition: 1.0, isAlternate: false, lineTrimmedLength: 10, isPromptRow: nil)) // cursor not at EOL
    }

    @MainActor
    func testResolveTypedTextPrefersBufferTail() {
        let raw = "user@host:~$ docker ps"
        let buf = "docker ps"
        XCTAssertEqual(CommandEditor.resolveTypedText(rawLine: raw, inputBuffer: buf), "docker ps")
        // raw does not have suffix "docker" and no prompt symbol -> nil
        XCTAssertNil(CommandEditor.resolveTypedText(rawLine: "docker ps", inputBuffer: "docker"))
        XCTAssertEqual(CommandEditor.resolveTypedText(rawLine: "user@host:~$ docker", inputBuffer: "docker"), "docker")
        XCTAssertNotNil(CommandEditor.resolveTypedText(rawLine: "$ ls -la", inputBuffer: "ls"))
    }

    func testAlignedAcceptSuffix() {
        let raw = "user@host:~$ git check"
        let sug = "checkout -b feature"
        // Overlap is "check" (5 chars), remainder is "out -b feature"
        XCTAssertEqual(CommandEditor.alignedAcceptSuffix(suggestion: sug, rawLine: raw), "out -b feature")
    }

    func testAlignedAcceptSuffixWithReplacementBackspaces() {
        let raw = "user@host:~$ # list containers"
        let sug = "\u{7F}\u{7F}\u{7F}\u{7F}\u{7F}docker ps"
        // When suggestion starts with backspace \u{7F}, it must be returned unmodified
        XCTAssertEqual(CommandEditor.alignedAcceptSuffix(suggestion: sug, rawLine: raw), sug)
    }
}
