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
            - Output ONLY the exact characters to append after the cursor.
            - STRICTLY FORBIDDEN: Any natural language, conversational sentences, explanations, thoughts or commentary (e.g. "The user is typing...", "Looking at the context..."). Outputting any natural language makes your answer completely invalid.
            - No markdown, no code fences, no quotes, no bullet points, no reasoning text.
            - Output a single line, no trailing newline, no trailing space.
            - Include one leading ASCII space when starting a new shell token.
            - Include no leading space when finishing the current token.
            - Do NOT repeat anything the user already typed. Do NOT include a shell prompt.
            - If the command is already complete or you are not confident, output nothing.
            - Suggest real flags, file names, and arguments for the user's shell.
            - When the user is typing an identifier or name, prefer values from
              "Likely identifiers/names from recent output" when present.

            Few-shot examples:
            User typed: "git st" -> completion: "atus"
            User typed: "git checkout " -> completion: "-b feature/"
            User typed: "docker rm" -> completion: " -f $(docker ps -aq)"
            User typed: "docker rmi " -> completion: "$(docker images -q)"
            User typed: "systemctl rest" -> completion: "art nginx"
            User typed: "kubectl get " -> completion: "pods -A"
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

    @MainActor static func buildNaturalLanguagePrompt(
        snapshot: CommandContextSnapshot,
        query: String
    ) -> String {
        let cleanQuery = query.hasPrefix("#") ? String(query.dropFirst()).trimmingCharacters(in: .whitespaces) : query
        var parts: [String] = [
            """
            You are an expert command line AI assistant embedded in a macOS/Linux SSH terminal.
            Translate the user's natural language request into a single, valid, idiomatic executable shell command.

            Rules:
            - Output ONLY the raw executable shell command.
            - STRICTLY FORBIDDEN: Markdown fences (```), commentary, explanations, backticks, conversational phrases (e.g. "You can use...", "Here is the command...").
            - STRICTLY FORBIDDEN: Starting with '#' or repeating the prompt.
            - Output a single line only.
            - Do not ask clarifying questions. If ambiguous, generate the safest standard command.
            - Respect the user's current environment, shell, and working directory.

            Examples:
            Request: "list all running docker containers" -> completion: "docker ps"
            Request: "find all files larger than 100MB in current dir" -> completion: "find . -type f -size +100M"
            Request: "restart nginx service" -> completion: "sudo systemctl restart nginx"
            Request: "查看当前系统内存使用情况" -> completion: "free -h"
            Request: "查看端口8080被谁占用" -> completion: "lsof -i :8080"
            """,
        ]
        var contextLines: [String] = []
        if let cwd = snapshot.currentDirectory, !cwd.isEmpty {
            contextLines.append("- Working directory: \(cwd)")
        }
        if let shell = snapshot.shell, !shell.isEmpty {
            contextLines.append("- Shell: \(shell)")
        }
        if !snapshot.recentCommands.isEmpty {
            let history = snapshot.recentCommands.suffix(5).joined(separator: "; ")
            contextLines.append("- Recent commands: \(history)")
        }
        if !contextLines.isEmpty {
            parts.append("Context:\n" + contextLines.joined(separator: "\n"))
        }
        parts.append("User Request: \"\(cleanQuery)\"")
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
        "flags", "true", "false", "root", "created", "ports",
        "error", "info", "help",
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
