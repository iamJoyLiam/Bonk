//
//  SearchCoordinator.swift
//  Bonk
//
//  Manages search state and coordinates between SwiftUI and SwiftTerm.
//  Provides bidirectional data flow for search functionality.
//

import Foundation
import SwiftTerm

/// Manages search state and coordinates between SwiftUI and SwiftTerm.
@Observable @MainActor
final class SearchCoordinator {
    // MARK: - State

    var searchText: String = ""
    var matchCount: Int = 0
    var currentMatch: Int = 0
    var isSearching: Bool = false

    // MARK: - Private

    private var debounceTask: Task<Void, Never>?
    private weak var terminalView: SwiftTerm.TerminalView?

    // MARK: - Public API

    /// Set the terminal view to search in.
    func setTerminalView(_ view: SwiftTerm.TerminalView) {
        self.terminalView = view
    }

    /// Update search text and trigger search.
    func search(_ term: String) {
        searchText = term
        debounceTask?.cancel()

        if term.isEmpty {
            matchCount = 0
            currentMatch = 0
            terminalView?.clearSearch()
            return
        }

        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            countMatches(term)
            currentMatch = 0
            isSearching = false
        }
        isSearching = true
    }

    /// Navigate to next match.
    func nextMatch() {
        guard !searchText.isEmpty, let terminalView else { return }
        let found = terminalView.findNext(searchText)
        if found {
            currentMatch = currentMatch >= matchCount ? 1 : currentMatch + 1
        }
    }

    /// Navigate to previous match.
    func previousMatch() {
        guard !searchText.isEmpty, let terminalView else { return }
        let found = terminalView.findPrevious(searchText)
        if found {
            currentMatch = currentMatch <= 1 ? matchCount : currentMatch - 1
        }
    }

    /// Clear search state.
    func clear() {
        searchText = ""
        matchCount = 0
        currentMatch = 0
        isSearching = false
        debounceTask?.cancel()
        terminalView?.clearSearch()
    }

    // MARK: - Private

    private func countMatches(_ term: String) {
        guard let terminalView, let terminal = terminalView.terminal else {
            matchCount = 0
            return
        }
        let start = Position(col: 0, row: 0)
        let end = Position(col: terminal.cols - 1, row: terminal.rows - 1)
        let text = terminal.getText(start: start, end: end)
        let lowerText = text.lowercased()
        let lowerTerm = term.lowercased()
        var count = 0
        var searchStart = lowerText.startIndex
        while searchStart < lowerText.endIndex,
              let range = lowerText[searchStart...].range(of: lowerTerm) {
            count += 1
            searchStart = range.upperBound
        }
        matchCount = count
    }
}
