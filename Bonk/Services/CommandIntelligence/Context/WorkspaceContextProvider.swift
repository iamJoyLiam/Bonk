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

    // P0.4: Cached KnownWords and output
    private var lastOutput: String = ""
    private var lastOutputHash: Int = 0
    private var cachedKnownWords: [String] = []

    // P0.4: Cached Host History
    private var lastHostKey: String = ""
    private var lastHistoryCount: Int = 0
    private var cachedHistoryCommands: [String] = []
    private var cachedLastExit: Int? = nil

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

        // P0.4: Incremental History Cache — avoid linear re-filtering during typing
        let allHistory = history.commands
        let historyCommands: [String]
        let lastExit: Int?
        if hostKey == lastHostKey, allHistory.count == lastHistoryCount {
            historyCommands = cachedHistoryCommands
            lastExit = cachedLastExit
        } else {
            let filtered = allHistory.filter { $0.hostKey == hostKey }
            historyCommands = Array(filtered.suffix(historyLimit).map(\.command))
            lastExit = filtered.last?.exitCode
            lastHostKey = hostKey
            lastHistoryCount = allHistory.count
            cachedHistoryCommands = historyCommands
            cachedLastExit = lastExit
        }

        // Use provided buffer or fall back to session inputBuffer (live typing)
        let buffer = inputBuffer ?? tab.session?.inputBuffer ?? ""

        // P0.4: Incremental Output & KnownWords Cache — skip regex parsing if output hasn't changed
        let outputHash = output.hashValue
        let knownWords: [String]
        if outputHash == lastOutputHash, output == lastOutput {
            knownWords = cachedKnownWords
        } else {
            knownWords = InlinePromptBuilder.extractKnownWords(from: output, limit: knownWordsLimit)
            lastOutput = output
            lastOutputHash = outputHash
            cachedKnownWords = knownWords
        }

        return CommandContextSnapshot(
            inputBuffer: buffer,
            hostKey: hostKey,
            currentDirectory: tab.currentDirectory,
            shell: tab.session?.serverInfo?.shell,
            recentCommands: historyCommands,
            recentOutput: output,
            lastExitCode: lastExit,
            knownWords: knownWords,
            selection: selection
        )
    }
}


