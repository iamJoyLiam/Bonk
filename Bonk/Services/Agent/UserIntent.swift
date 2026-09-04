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
    let isConversational: Bool

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
        let isConversational = isGreetingOrConversational(trimmedPrompt)
        // If there is no actionable text beyond @mentions, or if input is purely conversational greeting, execution is strictly false
        let canExecute = !trimmedPrompt.isEmpty && !isConversational && defaultExecutionRequested

        return UserIntent(
            rawInput: rawInput,
            contextReferences: mentions,
            prompt: trimmedPrompt,
            executionRequested: canExecute,
            isConversational: isConversational
        )
    }

    /// Detects if an input is a pure greeting, pleasantry, or self-introduction query rather than a terminal task.
    static func isGreetingOrConversational(_ text: String) -> Bool {
        let cleaned = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "！？。，~、!?., "))

        guard !cleaned.isEmpty else { return false }

        let exactMatches: Set<String> = [
            "你好", "您好", "哈喽", "嗨", "hi", "hello", "hey", "hi there", "hello there",
            "早上好", "下午好", "晚上好", "早安", "午安", "晚安", "早", "在吗", "在不在", "有人吗",
            "你是谁", "你能做什么", "你能干嘛", "你有什么功能", "介绍一下你自己",
            "who are you", "what can you do", "how are you", "greetings"
        ]

        if exactMatches.contains(cleaned) {
            return true
        }

        let conversationalPrefixes = ["你好", "您好", "哈喽", "hello", "hi", "hey"]
        for prefix in conversationalPrefixes {
            if cleaned.hasPrefix(prefix) {
                let remainder = cleaned.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "呀啊吧呢~ "))
                if remainder.isEmpty {
                    return true
                }
            }
        }

        return false
    }
}
