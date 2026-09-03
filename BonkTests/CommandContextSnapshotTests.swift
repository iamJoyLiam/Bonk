@testable import Bonk
import XCTest

final class CommandContextSnapshotTests: XCTestCase {
    func testSnapshotMatchesLegacyInlineContextProperties() {
        let legacy = InlineCompletionContext(
            inputBuffer: "git st",
            hostKey: "ssh:example",
            currentDirectory: "/work/bonk",
            shell: "/bin/zsh",
            recentCommands: ["git status", "git log -1"],
            recentOutput: "On branch main",
            lastExitCode: 0,
            knownWords: ["main", "origin"]
        )

        let snapshot = CommandContextSnapshot(
            inputBuffer: legacy.inputBuffer,
            hostKey: legacy.hostKey,
            currentDirectory: legacy.currentDirectory,
            shell: legacy.shell,
            recentCommands: legacy.recentCommands,
            recentOutput: legacy.recentOutput,
            lastExitCode: legacy.lastExitCode,
            knownWords: legacy.knownWords
        )

        XCTAssertEqual(snapshot.inputBuffer, legacy.inputBuffer)
        XCTAssertEqual(snapshot.hostKey, legacy.hostKey)
        XCTAssertEqual(snapshot.currentDirectory, legacy.currentDirectory)
        XCTAssertEqual(snapshot.shell, legacy.shell)
        XCTAssertEqual(snapshot.recentCommands, legacy.recentCommands)
        XCTAssertEqual(snapshot.recentOutput, legacy.recentOutput)
        XCTAssertEqual(snapshot.lastExitCode, legacy.lastExitCode)
        XCTAssertEqual(snapshot.knownWords, legacy.knownWords)
    }
}
