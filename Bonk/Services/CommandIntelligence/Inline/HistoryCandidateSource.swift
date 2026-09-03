//  HistoryCandidateSource.swift
//  Bonk
//
//  History-based instant suggestion — most recent command with typed prefix.
//  Pure, sync, deterministic. Extracted from InlineCompletionService.localSuggestion.
//

import Foundation

final class HistoryCandidateSource: SyncInlineCandidateSource, @unchecked Sendable {
    let name = "history"
    private let maxSuggestionChars: Int

    init(maxSuggestionChars: Int = InlineCompletionService.maxSuggestionChars) {
        self.maxSuggestionChars = maxSuggestionChars
    }

    func syncSuggestion(for snapshot: CommandContextSnapshot, typed: String) -> Suggestion? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        let suffix = Self.localSuffix(history: snapshot.recentCommands, typed: trimmed, maxChars: maxSuggestionChars)
        guard !suffix.isEmpty else { return nil }
        let display = InlineCompletionService.displaySuffix(suffix, typed: typed)
        return Suggestion(text: suffix, displayText: display)
    }

    /// Mirrors InlineCompletionService.localSuggestion precisely for parity.
    static func localSuffix(history: [String], typed: String, maxChars: Int) -> String {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { return "" }
        for cmd in history.reversed() {
            let candidate = cmd.trimmingCharacters(in: .whitespaces)
            guard candidate.count > typed.count else { continue }
            guard candidate.lowercased().hasPrefix(typed.lowercased()) else { continue }
            let suffix = String(candidate.dropFirst(typed.count))
            let normalized = Self.preserveLeadingSeparator(suffix)
            let core = normalized.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty, core.count <= maxChars else { continue }
            return normalized
        }
        return ""
    }

    private static func preserveLeadingSeparator(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .newlines)
        while text.last?.isWhitespace == true { text.removeLast() }
        let hasLeading = text.first?.isWhitespace == true
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return hasLeading ? " " + text : text
    }
}
