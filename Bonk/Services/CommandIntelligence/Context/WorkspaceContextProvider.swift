//  WorkspaceContextProvider.swift
//  Bonk
//
//  Intelligence owns snapshot — View provides raw Tab, Provider builds immutable snapshot.
//  Single place for host isolation, history slicing, output truncation, knownWords extraction.
//

import Foundation

/// Builds `CommandContextSnapshot` from workspace state.
/// Lives in Intelligence, not in Views. Testable via dependency injection.
@MainActor
protocol CommandContextProviding: Sendable {
    func snapshot(for tab: TerminalTab, inputBuffer: String?, selection: String?) -> CommandContextSnapshot
    func snapshot(for tab: TerminalTab) -> CommandContextSnapshot
}

@MainActor
final class WorkspaceContextProvider: CommandContextProviding {
    private let history: GlobalCommandHistory
    private let recentOutputLines: Int
    private let historyLimit: Int
    private let knownWordsLimit: Int

    init(
        history: GlobalCommandHistory = .shared,
        recentOutputLines: Int = 40,
        historyLimit: Int = 50,
        knownWordsLimit: Int = 30
    ) {
        self.history = history
        self.recentOutputLines = recentOutputLines
        self.historyLimit = historyLimit
        self.knownWordsLimit = knownWordsLimit
    }

    func snapshot(for tab: TerminalTab) -> CommandContextSnapshot {
        snapshot(for: tab, inputBuffer: nil, selection: nil)
    }

    func snapshot(for tab: TerminalTab, inputBuffer: String?, selection: String?) -> CommandContextSnapshot {
        let output = tab.session?.ptySession?.recentOutput(maxLines: recentOutputLines) ?? ""
        let hostKey = tab.hostItem.id.uuidString
        let historyCommands = history.commands
            .filter { $0.hostKey == hostKey }
            .suffix(historyLimit)
            .map(\.command)
        let lastExit = history.commands
            .filter { $0.hostKey == hostKey }
            .last?.exitCode

        // Use provided buffer or fall back to session inputBuffer (live typing)
        let buffer = inputBuffer ?? tab.session?.inputBuffer ?? ""

        // KnownWords extraction is Intelligence-owned pure function, not View-owned.
        // Reuse InlineCompletionService's proven extractor for parity (no behavior change in P0).
        let knownWords = InlineCompletionService.extractKnownWords(from: output, limit: knownWordsLimit)

        return CommandContextSnapshot(
            inputBuffer: buffer,
            hostKey: hostKey,
            currentDirectory: tab.currentDirectory,
            shell: tab.session?.serverInfo?.shell,
            recentCommands: Array(historyCommands),
            recentOutput: output,
            lastExitCode: lastExit,
            knownWords: knownWords,
            selection: selection
        )
    }
}

// MARK: - Convenience for Pane/Container callers (incremental migration)

extension WorkspaceContextProvider {
    /// Parity helper: build legacy context then convert — ensures 1:1 before switching callers.
    func legacyContext(for tab: TerminalTab) -> InlineCompletionContext {
        snapshot(for: tab).asLegacyInlineContext
    }
}
