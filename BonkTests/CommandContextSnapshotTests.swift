//
//  CommandContextSnapshotTests.swift
//  BonkTests
//
//  Parity: CommandContextSnapshot must be one-to-one with InlineCompletionContext (P0.1).
//

@testable import Bonk
import XCTest

final class CommandContextSnapshotTests: XCTestCase {
    func testSnapshotFields() {
        let snapshot = CommandContextSnapshot(
            inputBuffer: "docker ps",
            hostKey: "host-a",
            currentDirectory: "/var/www",
            shell: "/bin/zsh",
            recentCommands: ["cd /var/www", "ls"],
            recentOutput: "CONTAINER ID",
            lastExitCode: 0,
            knownWords: ["nginx", "web"]
        )
        XCTAssertEqual(snapshot.inputBuffer, "docker ps")
        XCTAssertEqual(snapshot.hostKey, "host-a")
        XCTAssertEqual(snapshot.currentDirectory, "/var/www")
        XCTAssertEqual(snapshot.shell, "/bin/zsh")
        XCTAssertEqual(snapshot.recentCommands, ["cd /var/www", "ls"])
        XCTAssertEqual(snapshot.recentOutput, "CONTAINER ID")
        XCTAssertEqual(snapshot.lastExitCode, 0)
        XCTAssertEqual(snapshot.knownWords, ["nginx", "web"])
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
