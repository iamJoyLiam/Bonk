//  CommandContextSnapshot.swift
//  Bonk
//
//  Immutable per-request snapshot owned by Command Intelligence.
//  One-to-one with legacy InlineCompletionContext for P0 parity.
//  All AI consumers (Inline / Chat / Agent / Error Explain / Inspector) will consume this.
//

import Foundation

/// Immutable snapshot of workspace + editor state for one AI request.
/// Intelligence owns this — Views/Workspace provide raw state, Provider builds snapshot.
/// Sendable + Equatable for caching, generation checks, and tests.
struct CommandContextSnapshot: Sendable, Equatable {
    /// Pure user-typed text (no prompt prefix), from the session input buffer.
    var inputBuffer: String
    /// Stable host/session scope. Prevents suggestions leaking across hosts.
    var hostKey: String?
    var currentDirectory: String?
    var shell: String?
    var recentCommands: [String]
    var recentOutput: String
    var lastExitCode: Int?
    /// Tool-agnostic identifiers extracted from recent output (container names,
    /// file names, branches, pods, ...) — no tool-specific parsing.
    var knownWords: [String]
    /// Optional user selection for Chat/Agent context (nil for Inline).
    var selection: String?
    /// Snapshot creation time — for TTL/debugging, not for equality.
    var timestamp: Date

    init(
        inputBuffer: String,
        hostKey: String? = nil,
        currentDirectory: String? = nil,
        shell: String? = nil,
        recentCommands: [String] = [],
        recentOutput: String = "",
        lastExitCode: Int? = nil,
        knownWords: [String] = [],
        selection: String? = nil,
        timestamp: Date = Date()
    ) {
        self.inputBuffer = inputBuffer
        self.hostKey = hostKey
        self.currentDirectory = currentDirectory
        self.shell = shell
        self.recentCommands = recentCommands
        self.recentOutput = recentOutput
        self.lastExitCode = lastExitCode
        self.knownWords = knownWords
        self.selection = selection
        self.timestamp = timestamp
    }

    // MARK: - Equatable (timestamp ignored for cache/key stability)

    static func == (lhs: CommandContextSnapshot, rhs: CommandContextSnapshot) -> Bool {
        lhs.inputBuffer == rhs.inputBuffer
            && lhs.hostKey == rhs.hostKey
            && lhs.currentDirectory == rhs.currentDirectory
            && lhs.shell == rhs.shell
            && lhs.recentCommands == rhs.recentCommands
            && lhs.recentOutput == rhs.recentOutput
            && lhs.lastExitCode == rhs.lastExitCode
            && lhs.knownWords == rhs.knownWords
            && lhs.selection == rhs.selection
    }

    // MARK: - Legacy bridging (parity)

    /// Initialize from legacy InlineCompletionContext — one-to-one field mapping.
    init(legacy: InlineCompletionContext, selection: String? = nil, timestamp: Date = Date()) {
        self.init(
            inputBuffer: legacy.inputBuffer,
            hostKey: legacy.hostKey,
            currentDirectory: legacy.currentDirectory,
            shell: legacy.shell,
            recentCommands: legacy.recentCommands,
            recentOutput: legacy.recentOutput,
            lastExitCode: legacy.lastExitCode,
            knownWords: legacy.knownWords,
            selection: selection,
            timestamp: timestamp
        )
    }

    /// Initialize from legacy TerminalContext (Chat/Agent) — best-effort mapping.
    init(legacy: TerminalContext, inputBuffer: String = "", knownWords: [String] = [], timestamp: Date = Date()) {
        self.init(
            inputBuffer: inputBuffer,
            hostKey: nil,
            currentDirectory: legacy.currentDirectory,
            shell: legacy.shell,
            recentCommands: legacy.recentCommands,
            recentOutput: legacy.terminalOutput ?? "",
            lastExitCode: nil,
            knownWords: knownWords,
            selection: legacy.selection,
            timestamp: timestamp
        )
    }

    /// Convert back to legacy InlineCompletionContext for incremental migration.
    var asLegacyInlineContext: InlineCompletionContext {
        InlineCompletionContext(
            inputBuffer: inputBuffer,
            hostKey: hostKey,
            currentDirectory: currentDirectory,
            shell: shell,
            recentCommands: recentCommands,
            recentOutput: recentOutput,
            lastExitCode: lastExitCode,
            knownWords: knownWords
        )
    }

    var asLegacyTerminalContext: TerminalContext {
        TerminalContext(
            currentDirectory: currentDirectory,
            shell: shell,
            recentCommands: recentCommands,
            terminalOutput: recentOutput.isEmpty ? nil : recentOutput,
            selection: selection
        )
    }
}
