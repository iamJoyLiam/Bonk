//  UserIntent.swift
//  Bonk
//
//  Separates user intent (action/execution requested) from context references (@history, @terminal).
//  Guarantees that context references alone never trigger unintended command execution loops.
//

import Foundation

struct UserIntent: Sendable, Equatable {
    let rawInput: String
    let contextReferences: [AIContextMention]
    let prompt: String
    let executionRequested: Bool

    /// Parses user input into actionable prompt vs attached context references.
    static func parse(rawInput: String, defaultExecutionRequested: Bool = false) -> UserIntent {
        var mentions: [AIContextMention] = []
        var cleaned = rawInput

        for mention in AIContextMention.allCases {
            if cleaned.contains(mention.rawValue) {
                mentions.append(mention)
                cleaned = cleaned.replacingOccurrences(of: mention.rawValue, with: "")
            }
        }

        let trimmedPrompt = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // If there is no actionable text beyond @mentions, execution is strictly false
        let canExecute = !trimmedPrompt.isEmpty && defaultExecutionRequested

        return UserIntent(
            rawInput: rawInput,
            contextReferences: mentions,
            prompt: trimmedPrompt,
            executionRequested: canExecute
        )
    }
}
