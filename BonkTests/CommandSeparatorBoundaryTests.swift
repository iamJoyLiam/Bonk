//
//  CommandSeparatorBoundaryTests.swift
//  BonkTests
//
//  The shell has separators. The classifier has to know what they are.
//
//  A command reaches a remote login shell as one string, and that shell splits
//  it on newlines, carriage returns, `;`, `|`, `&&` and a bare `&`. If the
//  classifier does not model a separator the shell honours, then the segments
//  on either side of it are never classified separately — and a string whose
//  first segment is innocuous reads as one safe command.
//
//      model output "ls\nreboot"
//        -> classifier sees ONE segment, matches no exact-set entry
//        -> .l1SafeInspection
//        -> policy returns .allowed, in every access mode including readOnly
//        -> ssh hands the string to the login shell, which runs both
//
//  These tests deliberately assert the *decision* — `evaluate(...)` must not
//  return `.allowed`, and the level must reach L3 — rather than how many
//  segments the splitter returns. A structural assertion would stay green the
//  next time the splitter is edited into a different wrong shape, which is
//  exactly how `CommandSafetyBypassTests` came to pass: its nine vectors are
//  all single-line, so the suite's stated invariant held for every shape it
//  named while the shape it did not name was live.
//
//  The authority whose decision is under test is the one in
//  `AgentRuntime.runToolCall`: untrusted model text in, `PermissionDecision`
//  out, with the access mode applied.
//

import Foundation
import Testing
@testable import Bonk

@Suite("Command separators are classified, not smuggled")
struct CommandSeparatorBoundaryTests {

    private let runCommand = "run_command"

    private func decision(
        _ command: String,
        _ mode: AgentMessage.AccessMode
    ) -> PermissionDecision {
        DefaultAgentPermissionPolicy(accessMode: mode)
            .evaluate(tool: runCommand, arguments: ["command": command])
    }

    private let allModes: [AgentMessage.AccessMode] = [.readOnly, .supervised, .fullAccess]

    // MARK: - Preconditions

    /// If these stop holding, the vectors below prove nothing: either the
    /// innocuous half is no longer innocuous or the dangerous half is no
    /// longer dangerous, and a failure would be the fixture's fault.
    @Test("precondition: each half classifies on its own")
    func halvesClassifyIndependently() {
        #expect(CommandSafety.classifyLevel("ls") == .l1SafeInspection)
        #expect(CommandSafety.classifyLevel("reboot") == .l3HighRisk)
        #expect(CommandSafety.classifyLevel("ls") != CommandSafety.classifyLevel("reboot"))
    }

    // MARK: - The gap

    /// A newline is a command separator to the shell that will run this.
    @Test("a newline between two commands is not one safe command")
    func newlineIsASeparator() {
        let vectors = [
            "ls\nreboot",
            "ls\r\nreboot",
            // Written by concatenation on purpose: in "\reboot" the lexer eats
            // the `r` of `reboot` as part of the escape, yielding "ls" CR
            // "eboot" — a harmless second segment that correctly classifies L1.
            // That is a wrong test vector, not a wrong classifier.
            "ls\r" + "reboot",
            "\nreboot",
            "reboot\n",
            "\n\nreboot\n\n",
        ]
        for mode in allModes {
            let decisions = vectors.map { decision($0, mode) }
            #expect(
                decisions.allSatisfy { $0 != .allowed },
                "a newline-separated pair must never be allowed, in any access mode"
            )
        }
        // Precisely L3, not merely "not allowed": the dangerous verb has to be
        // recognised. A blanket block would satisfy the assertion above while
        // quietly breaking every legitimate command.
        #expect(CommandSafety.classifyLevel("ls\nreboot") == .l3HighRisk)
        #expect(CommandSafety.classifyLevel("ls\r\nreboot") == .l3HighRisk)
    }

    /// The severity does not depend on the innocuous half being `ls`.
    @Test("state-mutating and critical verbs are equally reachable")
    func otherVerbsAreReachable() {
        for verb in ["userdel bob", "iptables -F", "systemctl stop nginx", "passwd", "launchctl unload x"] {
            for mode in allModes {
                #expect(decision("ls\n\(verb)", mode) != .allowed)
            }
        }
    }

    // MARK: - The fix must not over-block

    /// A newline inside quotes is a literal character to the shell, so
    /// splitting on it would misclassify ordinary commands.
    @Test("a newline inside quotes stays literal")
    func quotedNewlineIsNotASeparator() {
        #expect(decision("echo \"line one\nline two\"", .readOnly) == .allowed)
        #expect(decision("echo 'a\nb'", .readOnly) == .allowed)
        // A quoted dangerous verb is a string, not a command. The command is
        // still `echo`, so this is L1 either way — what matters is that the
        // quotes did not turn one command into two.
        #expect(CommandSafety.classifyLevel("echo \"reboot\"") == .l1SafeInspection)
    }

    /// Ordinary single-line safety is untouched.
    @Test("ordinary commands are unaffected")
    func ordinaryCommandsUnaffected() {
        #expect(decision("ls -la", .readOnly) == .allowed)
        #expect(decision("git status", .readOnly) == .allowed)
        #expect(CommandSafety.classifyLevel("reboot") == .l3HighRisk)
        #expect(CommandSafety.classifyLevel("rm -rf /") == .l4Critical)
    }

    /// Empty and whitespace-only input must not become an allowance.
    @Test("separator-only input is not an executable safe command")
    func separatorOnlyInput() {
        for junk in ["\n", "\r\n", "\n\n", " ", "\n \n"] {
            #expect(decision(junk, .readOnly) != .allowed)
        }
    }

    /// The same invariant asserted against the classifier directly.
    ///
    /// `decision(_:_:)` trims the command before classifying, so it cannot
    /// distinguish a newline-aware trim in `classify` from a plain one — the
    /// policy's own trim hides the difference. Without this, reverting
    /// `classify` to `.whitespaces` is an equivalent mutation that no test
    /// notices, and a string consisting only of separators would classify as
    /// `.safe`: the splitter drops the empty segments, the loop never runs, and
    /// `highestRisk` keeps its `.safe` initial value.
    @Test("separator-only input is not classified as a safe command")
    func separatorOnlyClassifiesAsBlocked() {
        for junk in ["\n", "\r\n", "\n\n", "\r", "\n \n", " \n "] {
            #expect(CommandSafety.classifyLevel(junk) == .l4Critical)
        }
    }
}
