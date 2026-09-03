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
        var parts: [String] = [
            """
            You are an inline shell command completion engine embedded in an SSH terminal, \
            like GitHub Copilot or Warp. The user is typing a shell command.
            Complete the command they are typing.

            Rules:
            - Output ONLY the text that should be appended after the cursor.
            - No explanation, no markdown, no code fences, no quotes, no bullet points.
            - Output a single line, no trailing newline, no trailing space.
            - Include one leading ASCII space when starting a new shell token.
            - Include no leading space when finishing the current token.
            - Do NOT repeat anything the user already typed. Do NOT include a shell prompt.
            - If the command is already complete or you are not confident, output nothing.
            - Suggest real flags, file names, and arguments for the user's shell.
            - When the user is typing an identifier or name, prefer values from
              "Likely identifiers/names from recent output" when present.
            """,
        ]
        var contextLines: [String] = []
        if includeEnv, let cwd = snapshot.currentDirectory, !cwd.isEmpty {
            contextLines.append("- Working directory: \(cwd)")
        }
        if let shell = snapshot.shell, !shell.isEmpty {
            contextLines.append("- Shell: \(shell)")
        }
        if let exitCode = snapshot.lastExitCode {
            contextLines.append("- Last command exit code: \(exitCode)")
        }
        if includeHistory, !snapshot.recentCommands.isEmpty {
            let history = snapshot.recentCommands.suffix(5).joined(separator: "; ")
            contextLines.append("- Recent commands: \(history)")
        }
        if !approvedExamples.isEmpty {
            contextLines.append("- User-approved completions (prefix → suffix):\n" + approvedExamples.joined(separator: "\n"))
        }
        if includeOutput, !snapshot.recentOutput.isEmpty {
            let output = stripANSI(String(snapshot.recentOutput.suffix(600)))
            contextLines.append("- Recent terminal output:\n\(output)")
        }
        if includeOutput, !snapshot.knownWords.isEmpty {
            let words = snapshot.knownWords.prefix(30).joined(separator: ", ")
            contextLines.append("- Likely identifiers/names from recent output: \(words)")
        }
        if !contextLines.isEmpty {
            parts.append("Context:\n" + contextLines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func extractKnownWords(from output: String, limit: Int = 30) -> [String] {
        let cleaned = stripANSI(output)
        let tokens = cleaned.split { ch in !(ch.isLetter || ch.isNumber || "._/-".contains(ch)) }
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            let word = String(token)
            guard word.count >= 2, word.count <= 40,
                  word.rangeOfCharacter(from: .letters) != nil,
                  !word.hasPrefix("-"),
                  !noiseWords.contains(word.lowercased()),
                  seen.insert(word.lowercased()).inserted else { continue }
            result.append(word)
            if result.count >= limit { break }
        }
        return result
    }

    private static let noiseWords: Set<String> = [
        "usage", "command", "name", "names", "total", "type", "mode", "size",
        "flags", "true", "false", "root", "docker", "ps", "logs", "run", "exec",
        "error", "info", "help", "status", "up", "down", "created", "ports",
    ]

    static func stripANSI(_ text: String) -> String {
        // Reuse InlineCompletionService's strip via knownWords path for parity;
        // InlineCompletionService.stripANSI is private, so we replicate via extract path.
        // For P0, delegate to a simple regex identical to Service's.
        guard let regex = try? NSRegularExpression(pattern: #"\x1B(?:\[[0-9;?]*[a-zA-Z]|\][^\x07\x1B]*(?:\x07|\x1B\\))"#) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
