//
//  InlineCompletionTests.swift
//  BonkTests
//

@testable import Bonk
import XCTest

final class InlineCompletionTests: XCTestCase {
    // MARK: - commandText (prompt prefix stripping)

    func testCommandTextStripsUserAtHostPrompt() {
        XCTAssertEqual(
            InlineCompletionService.commandText(from: "user@host:~$ docker ru"),
            "docker ru"
        )
    }

    func testCommandTextStripsRootPrompt() {
        XCTAssertEqual(
            InlineCompletionService.commandText(from: "root@box:/var/www# ls -la"),
            "ls -la"
        )
    }

    func testCommandTextStripsBarePrompt() {
        XCTAssertEqual(InlineCompletionService.commandText(from: "$ git status"), "git status")
        XCTAssertEqual(InlineCompletionService.commandText(from: "# whoami"), "whoami")
    }

    func testCommandTextStripsFishPrompt() {
        XCTAssertEqual(InlineCompletionService.commandText(from: "❯ docker ps"), "docker ps")
    }

    func testCommandTextStripsZshArrowPrompt() {
        // The cwd token after the arrow is kept — harmless, since only the
        // completion suffix (after the cursor) is ever rendered as ghost text.
        XCTAssertEqual(InlineCompletionService.commandText(from: "➜  ~ git log"), "~ git log")
    }

    func testCommandTextStripsPS2ContinuationPrompt() {
        XCTAssertEqual(InlineCompletionService.commandText(from: "> --force"), "--force")
    }

    func testCommandTextReturnsNilWithoutPromptSymbol() {
        XCTAssertNil(InlineCompletionService.commandText(from: "docker ps"))
        XCTAssertNil(InlineCompletionService.commandText(from: ""))
    }

    func testCommandTextDoesNotSplitDollarVariables() {
        // `$BAR` has no whitespace after `$` — must not be treated as a prompt.
        XCTAssertEqual(
            InlineCompletionService.commandText(from: "user@host:~$ echo $BAR"),
            "echo $BAR"
        )
    }

    func testCommandTextDoesNotSplitFileRedirect() {
        // Prompt appears before the redirect, so extraction must stop there.
        XCTAssertEqual(
            InlineCompletionService.commandText(from: "user@host:~$ cat a.txt > b.txt"),
            "cat a.txt > b.txt"
        )
    }

    func testCommandTextReturnsNilWhenOnlyPrompt() {
        XCTAssertNil(InlineCompletionService.commandText(from: "user@host:~$ "))
    }

    // MARK: - normalize

    func testNormalizeTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(InlineCompletionService.normalize("  docker run -d  \n"), "docker run -d")
    }

    func testNormalizeKeepsSingleLine() {
        XCTAssertEqual(InlineCompletionService.normalize("git push origin main"), "git push origin main")
    }

    func testNormalizeTakesFirstLineOnly() {
        XCTAssertEqual(InlineCompletionService.normalize("git push\ngit status"), "git push")
    }

    func testNormalizeRejectsMarkdownFences() {
        XCTAssertEqual(InlineCompletionService.normalize("```bash\ndocker run\n```"), "")
    }

    func testNormalizeRejectsPromptLeftovers() {
        XCTAssertEqual(InlineCompletionService.normalize("$ docker run"), "")
        XCTAssertEqual(InlineCompletionService.normalize("# whoami"), "")
    }

    func testNormalizeRejectsEmpty() {
        XCTAssertEqual(InlineCompletionService.normalize(""), "")
        XCTAssertEqual(InlineCompletionService.normalize("   \n"), "")
    }

    func testNormalizeRejectsOverlongSuggestions() {
        let long = String(repeating: "a", count: 201)
        XCTAssertEqual(InlineCompletionService.normalize(long), "")
    }

    // MARK: - buildPrompt

    func testBuildPromptHonorsContextFlags() {
        let context = InlineCompletionContext(
            inputBuffer: "docker",
            currentDirectory: "/var/www",
            recentCommands: ["cd /var/www", "ls"],
            recentOutput: "app/  public/\n"
        )

        let full = InlineCompletionService.buildPrompt(
            context: context, includeOutput: true, includeHistory: true, includeEnv: true
        )
        XCTAssertTrue(full.contains("Working directory: /var/www"))
        XCTAssertTrue(full.contains("cd /var/www"))
        XCTAssertTrue(full.contains("Recent terminal output"))
        XCTAssertTrue(full.contains("app/  public/"))

        let minimal = InlineCompletionService.buildPrompt(
            context: context, includeOutput: false, includeHistory: false, includeEnv: false
        )
        XCTAssertFalse(minimal.contains("Working directory"))
        XCTAssertFalse(minimal.contains("cd /var/www"))
        XCTAssertFalse(minimal.contains("Recent terminal output"))
    }

    func testBuildPromptContainsCompletionRules() {
        let context = InlineCompletionContext(
            inputBuffer: "git", currentDirectory: nil, recentCommands: [], recentOutput: ""
        )
        let prompt = InlineCompletionService.buildPrompt(
            context: context,
            includeOutput: false, includeHistory: false, includeEnv: false
        )
        XCTAssertTrue(prompt.contains("appended after the cursor"))
        XCTAssertTrue(prompt.contains("Do NOT repeat anything"))
    }

    // MARK: - localSuggestion (instant history fallback)

    func testLocalSuggestionMatchesMostRecentCommand() {
        let history = ["cd /tmp", "docker ps", "docker run -d nginx"]
        XCTAssertEqual(
            InlineCompletionService.localSuggestion(history: history, typed: "docker"),
            "run -d nginx"
        )
    }

    func testLocalSuggestionMatchesMidCommand() {
        let history = ["docker run -d --name web nginx", "ls -la"]
        XCTAssertEqual(
            InlineCompletionService.localSuggestion(history: history, typed: "docker run"),
            "-d --name web nginx"
        )
    }

    func testLocalSuggestionPrefersRecentOverOlder() {
        let history = ["docker run -d nginx", "cd /tmp", "docker ps"]
        XCTAssertEqual(
            InlineCompletionService.localSuggestion(history: history, typed: "docker"),
            "ps"
        )
    }

    func testLocalSuggestionSkipsIdenticalOrShorter() {
        let history = ["docker", "docker ps", "cd /tmp"]
        XCTAssertEqual(
            InlineCompletionService.localSuggestion(history: history, typed: "docker"),
            "ps"
        )
    }

    func testLocalSuggestionEmptyWithoutMatch() {
        let history = ["cd /tmp", "ls -la"]
        XCTAssertEqual(
            InlineCompletionService.localSuggestion(history: history, typed: "git"),
            ""
        )
        XCTAssertEqual(
            InlineCompletionService.localSuggestion(history: history, typed: "l"),
            ""
        )
    }

    func testLocalSuggestionSkipsOverlong() {
        let long = "a" + String(repeating: "b", count: 300)
        XCTAssertEqual(
            InlineCompletionService.localSuggestion(history: [long], typed: "a"),
            ""
        )
    }
}
