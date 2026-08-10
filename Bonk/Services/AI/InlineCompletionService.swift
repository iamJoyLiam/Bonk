//
//  InlineCompletionService.swift
//  Bonk
//
//  Warp-style inline AI command completion: watches typing pauses at a shell
//  prompt, asks the active AI provider to complete the current command, and
//  exposes the suggestion as ghost text (Tab accepts, Esc dismisses).
//

import Foundation
import Observation
import os.log

/// Snapshot of terminal state used as context for a completion request.
/// Fetched lazily at request time, so it always reflects the current line.
struct InlineCompletionContext {
    /// Pure user-typed text (no prompt prefix), from the session input buffer.
    var inputBuffer: String
    var currentDirectory: String?
    var recentCommands: [String]
    var recentOutput: String
}

/// Owns the inline completion request lifecycle. @MainActor: the only caller
/// (NativeTerminalView) lives on the main thread.
@Observable @MainActor
final class InlineCompletionService {
    static let shared = InlineCompletionService()

    /// The pending suggestion (empty when none). Rendered as ghost text.
    private(set) var suggestion: String = ""
    private(set) var isRequesting = false
    var lastError: String?

    private let providerStore: AIProviderStore
    private let defaults: UserDefaults
    private var currentTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.bonk", category: "InlineCompletion")

    /// Tokens budget — suggestions are short; keep latency and cost low.
    private static let maxSuggestionTokens = 60
    /// Cap on suggestion length to avoid a runaway model hijacking the line.
    private static let maxSuggestionChars = 200

    init(providerStore: AIProviderStore = .shared, defaults: UserDefaults = .standard) {
        self.providerStore = providerStore
        self.defaults = defaults
    }

    // MARK: - Settings

    var isEnabled: Bool {
        defaults.bool(forKey: "ai_enabled") && defaults.bool(forKey: "ai_inline_suggestions")
    }

    var debounceMilliseconds: Int {
        let raw = defaults.integer(forKey: "ai_debounce_ms")
        return raw > 0 ? raw : 500
    }

    private var includeTerminalOutput: Bool {
        defaults.object(forKey: "ai_include_terminal") == nil || defaults.bool(forKey: "ai_include_terminal")
    }

    private var includeCommandHistory: Bool {
        defaults.object(forKey: "ai_include_history") == nil || defaults.bool(forKey: "ai_include_history")
    }

    private var includeEnvironmentInfo: Bool {
        defaults.bool(forKey: "ai_include_env")
    }

    // MARK: - Request Lifecycle

    /// Start (or replace) a completion request for the given context.
    /// Cancels any in-flight request — one suggestion per typing pause.
    /// `onSuggestion` fires on the main actor when a suggestion is ready.
    func request(
        context: InlineCompletionContext,
        onSuggestion: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        currentTask?.cancel()
        suggestion = ""
        lastError = nil

        guard isEnabled else { return }
        guard let (provider, apiKey) = resolveProvider() else { return }
        let typed = context.inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return }

        isRequesting = true
        let prompt = Self.buildPrompt(
            context: context,
            includeOutput: includeTerminalOutput,
            includeHistory: includeCommandHistory,
            includeEnv: includeEnvironmentInfo
        )

        currentTask = Task { [weak self] in
            defer { self?.isRequesting = false }
            guard let self else { return }
            do {
                let response = try await AIProviderNetworking.streamRequest(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: prompt, userPrompt: typed,
                    maxTokens: Self.maxSuggestionTokens
                )
                guard !Task.isCancelled else { return }
                let normalized = Self.normalize(response)
                guard !normalized.isEmpty else {
                    Self.logger.debug("completion: empty suggestion for \(typed, privacy: .public)")
                    return
                }
                suggestion = normalized
                Self.logger.info("completion: suggested \(normalized.count) chars for \(typed, privacy: .public)")
                onSuggestion?(normalized)
            } catch {
                if Task.isCancelled { return }
                lastError = error.localizedDescription
                Self.logger.error("completion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Consume and clear the suggestion (Tab). Returns the text to send.
    func accept() -> String {
        let result = suggestion
        suggestion = ""
        currentTask?.cancel()
        isRequesting = false
        return result
    }

    /// Cancel any request and clear the suggestion (Esc / any other input).
    func dismiss() {
        currentTask?.cancel()
        currentTask = nil
        suggestion = ""
        isRequesting = false
    }

    // MARK: - Provider

    private func resolveProvider() -> (AIProviderConfig, String)? {
        guard let provider = providerStore.activeProvider else { return nil }
        let key = provider.apiKey
        guard !key.isEmpty else { return nil }
        return (provider, key)
    }

    // MARK: - Prompt

    /// Build the system prompt for a completion request.
    /// Pure function so it is unit-testable.
    static func buildPrompt(
        context: InlineCompletionContext,
        includeOutput: Bool,
        includeHistory: Bool,
        includeEnv: Bool
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
            - Do NOT repeat anything the user already typed. Do NOT include a shell prompt.
            - If the command is already complete or you are not confident, output nothing.
            - Suggest real flags, file names, and arguments for the user's shell.
            """,
        ]

        var contextLines: [String] = []
        if includeEnv, let cwd = context.currentDirectory, !cwd.isEmpty {
            contextLines.append("- Working directory: \(cwd)")
        }
        if includeHistory, !context.recentCommands.isEmpty {
            let history = context.recentCommands.suffix(8).joined(separator: "; ")
            contextLines.append("- Recent commands: \(history)")
        }
        if includeOutput, !context.recentOutput.isEmpty {
            let output = String(context.recentOutput.suffix(2000))
            contextLines.append("- Recent terminal output:\n\(output)")
        }
        if !contextLines.isEmpty {
            parts.append("Context:\n" + contextLines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Output Normalization

    /// Clean a model response into a single-line suggestion.
    /// Pure function so it is unit-testable.
    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // Single line only — a multi-line suggestion would wreck the prompt.
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[..<newline]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return "" }

        // Reject markdown-wrapped responses outright.
        if text.contains("```") { return "" }
        guard text.count <= maxSuggestionChars else { return "" }

        // Never suggest shell prompt leftovers.
        if text.range(of: #"^[>\$#%❯➜]\s+"#, options: .regularExpression) != nil { return "" }
        return text
    }

    // MARK: - Prompt Prefix Stripping

    /// Extract the command part from a terminal line that may contain a shell
    /// prompt prefix (e.g. `user@host:~$ docker ru` → `docker ru`).
    /// Matches the first prompt symbol followed by whitespace and a command.
    /// Pure function so it is unit-testable.
    static func commandText(from line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[>%$#❯➜]\s+(\S.*)$"#) else { return nil }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }
        let group = match.range(at: 1)
        guard group.location != NSNotFound else { return nil }
        let cmd = nsLine.substring(with: group).trimmingCharacters(in: .whitespaces)
        return cmd.isEmpty ? nil : cmd
    }
}
