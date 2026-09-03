//  InlinePromptBuilder.swift
//  Bonk
//
//  Pure prompt construction + ANSI stripping + knownWords extraction.
//  Extracted from InlineCompletionService for testability and reuse by LLMCandidateSource.
//

import Foundation

enum InlinePromptBuilder {
    @MainActor static func buildPrompt(
        snapshot: CommandContextSnapshot,
        includeOutput: Bool = true,
        includeHistory: Bool = true,
        includeEnv: Bool = false,
        approvedExamples: [String] = []
    ) -> String {
        InlineCompletionService.buildPrompt(
            context: snapshot.asLegacyInlineContext,
            includeOutput: includeOutput,
            includeHistory: includeHistory,
            includeEnv: includeEnv,
            approvedExamples: approvedExamples
        )
    }

    static func extractKnownWords(from output: String, limit: Int = 30) -> [String] {
        InlineCompletionService.extractKnownWords(from: output, limit: limit)
    }

    static func stripANSI(_ text: String) -> String {
        // Reuse InlineCompletionService's strip via knownWords path for parity;
        // InlineCompletionService.stripANSI is private, so we replicate via extract path.
        // For P0, delegate to a simple regex identical to Service's.
        guard let regex = try? NSRegularExpression(pattern: #"\x1B(?:\[[0-9;?]*[a-zA-Z]|\][^\x07\x1B]*(?:\x07|\x1B\\))"#) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
