//
//  CommandContextSnapshot.swift
//  Bonk
//
//  Shared immutable context snapshot for AI requests.
//  P0 scaffolding: mirrors the existing InlineCompletionContext without
//  changing the current completion behavior.
//

import Foundation

/// Immutable-at-request-boundary snapshot of the workspace state visible to AI.
///
/// This type intentionally contains only the values currently exposed by the
/// legacy inline context. It is Sendable so a request may safely carry the
/// snapshot across async boundaries without observing later terminal changes.
struct CommandContextSnapshot: Sendable, Equatable {
    /// Pure user-typed text (no prompt prefix).
    let inputBuffer: String

    /// Stable host/session scope. Prevents suggestions leaking across hosts.
    let hostKey: String?

    let currentDirectory: String?
    let shell: String?
    let recentCommands: [String]
    let recentOutput: String
    let lastExitCode: Int?

    /// Tool-agnostic identifiers extracted from recent output.
    let knownWords: [String]

    init(
        inputBuffer: String,
        hostKey: String?,
        currentDirectory: String?,
        shell: String?,
        recentCommands: [String],
        recentOutput: String,
        lastExitCode: Int?,
        knownWords: [String]
    ) {
        self.inputBuffer = inputBuffer
        self.hostKey = hostKey
        self.currentDirectory = currentDirectory
        self.shell = shell
        self.recentCommands = recentCommands
        self.recentOutput = recentOutput
        self.lastExitCode = lastExitCode
        self.knownWords = knownWords
    }
}
