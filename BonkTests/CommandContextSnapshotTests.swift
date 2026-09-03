//
//  CommandContextSnapshotTests.swift
//  BonkTests
//
//  Parity: CommandContextSnapshot must be one-to-one with InlineCompletionContext (P0.1).
//

@testable import Bonk
import XCTest

final class CommandContextSnapshotTests: XCTestCase {
    func testParityWithInlineCompletionContext() {
        let legacy = InlineCompletionContext(
            inputBuffer: "docker ps",
            hostKey: "host-a",
            currentDirectory: "/var/www",
            shell: "/bin/zsh",
            recentCommands: ["cd /var/www", "ls"],
            recentOutput: "CONTAINER ID",
            lastExitCode: 0,
            knownWords: ["nginx", "web"]
        )
        let snapshot = CommandContextSnapshot(legacy: legacy)
        XCTAssertEqual(snapshot.inputBuffer, legacy.inputBuffer)
        XCTAssertEqual(snapshot.hostKey, legacy.hostKey)
        XCTAssertEqual(snapshot.currentDirectory, legacy.currentDirectory)
        XCTAssertEqual(snapshot.shell, legacy.shell)
        XCTAssertEqual(snapshot.recentCommands, legacy.recentCommands)
        XCTAssertEqual(snapshot.recentOutput, legacy.recentOutput)
        XCTAssertEqual(snapshot.lastExitCode, legacy.lastExitCode)
        XCTAssertEqual(snapshot.knownWords, legacy.knownWords)
        // round-trip
        let back = snapshot.asLegacyInlineContext
        XCTAssertEqual(back.inputBuffer, legacy.inputBuffer)
        XCTAssertEqual(back.hostKey, legacy.hostKey)
        XCTAssertEqual(back.currentDirectory, legacy.currentDirectory)
        XCTAssertEqual(back.shell, legacy.shell)
        XCTAssertEqual(back.recentCommands, legacy.recentCommands)
        XCTAssertEqual(back.recentOutput, legacy.recentOutput)
        XCTAssertEqual(back.lastExitCode, legacy.lastExitCode)
        XCTAssertEqual(back.knownWords, legacy.knownWords)
    }

    func testParityWithTerminalContext() {
        let legacy = TerminalContext(
            currentDirectory: "/tmp",
            shell: "/bin/bash",
            recentCommands: ["ls", "pwd"],
            terminalOutput: "output",
            selection: "sel"
        )
        let snapshot = CommandContextSnapshot(legacy: legacy, inputBuffer: "ls", knownWords: ["a"])
        XCTAssertEqual(snapshot.currentDirectory, legacy.currentDirectory)
        XCTAssertEqual(snapshot.shell, legacy.shell)
        XCTAssertEqual(snapshot.recentCommands, legacy.recentCommands)
        XCTAssertEqual(snapshot.recentOutput, legacy.terminalOutput)
        XCTAssertEqual(snapshot.selection, legacy.selection)
        XCTAssertEqual(snapshot.inputBuffer, "ls")
        XCTAssertEqual(snapshot.knownWords, ["a"])
    }

    func testEquatableIgnoresTimestamp() {
        let a = CommandContextSnapshot(inputBuffer: "x", timestamp: Date())
        let b = CommandContextSnapshot(inputBuffer: "x", timestamp: Date().addingTimeInterval(100))
        XCTAssertEqual(a, b)
    }

    func testSelectionPreserved() {
        let snap = CommandContextSnapshot(inputBuffer: "hi", selection: "sel")
        XCTAssertEqual(snap.selection, "sel")
        let back = snap.asLegacyTerminalContext
        XCTAssertEqual(back.selection, "sel")
    }
}
