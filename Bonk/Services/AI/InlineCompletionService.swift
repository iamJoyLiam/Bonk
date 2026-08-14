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

    /// Tokens budget — suggestions are short, but reasoning models (e.g.
    /// DeepSeek V4) burn tokens on thinking before any visible content,
    /// so 200 leaves room for an actual suggestion.
    nonisolated static let maxSuggestionTokens = 200
    /// Cap on suggestion length to avoid a runaway model hijacking the line.
    nonisolated static let maxSuggestionChars = 200
    /// Hard cap on how long a suggestion request may take. Suggestions that
    /// arrive late feel broken — keep it short (Warp-style: fast or nothing).
    nonisolated static let requestTimeout: Duration = .seconds(3)

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
    ///
    /// Strategy (Warp-style: fast or nothing):
    /// 1. Show an instant suggestion from command history before the model
    ///    even connects — no waiting for a slow provider's TTFT.
    /// 2. Fire the model request in the background; when it streams in it
    ///    replaces the local suggestion with a smarter one.
    /// 3. If the model comes back empty or errors out, keep the local
    ///    suggestion instead of wiping a visible ghost.
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

        // Instant local fallback — history is the fastest, most accurate
        // predictor for commands the user has already run. Gated by the same
        // setting that controls history in the model prompt.
        if includeCommandHistory, !context.recentCommands.isEmpty {
            let local = Self.localSuggestion(history: context.recentCommands, typed: typed)
            if !local.isEmpty {
                suggestion = local
                onSuggestion?(local)
            }
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.streamModelSuggestion(
                provider: provider, apiKey: apiKey,
                prompt: prompt, typed: typed, onSuggestion: onSuggestion
            )
        }
    }

    /// Stream the model suggestion in the background. The local history
    /// suggestion stays visible until the model produces a real replacement —
    /// an empty or failed model response never wipes a visible ghost.
    @MainActor
    private func streamModelSuggestion(
        provider: AIProviderConfig,
        apiKey: String,
        prompt: String,
        typed: String,
        onSuggestion: (@MainActor @Sendable (String) -> Void)?
    ) async {
        defer { isRequesting = false }
        let buffer = RawSuggestionBuffer()
        do {
            let response = try await Self.runWithTimeout {
                try await AIProviderNetworking.streamRequest(
                    provider: provider, apiKey: apiKey,
                    systemPrompt: prompt, userPrompt: typed,
                    maxTokens: Self.maxSuggestionTokens,
                    disableReasoning: true
                ) { [weak self] delta in
                    // Show the ghost as soon as the first tokens arrive —
                    // waiting for the full stream makes slow providers feel
                    // broken. `suggestion` updates so Tab works mid-stream.
                    let candidate = Self.suggestionSuffix(from: buffer.append(delta), typed: typed)
                    guard !candidate.isEmpty,
                          candidate.count <= Self.maxSuggestionChars
                    else { return }
                    Task { @MainActor [weak self] in
                        self?.suggestion = candidate
                        onSuggestion?(candidate)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let suffix = Self.suggestionSuffix(from: response, typed: typed)
            if !suffix.isEmpty {
                suggestion = suffix
                onSuggestion?(suffix)
            }
        } catch is CancellationError {
            // Timed out or superseded. If a suggestion is already showing,
            // keep it — killing a visible ghost mid-read feels broken.
            if suggestion.isEmpty {
                onSuggestion?("")
            }
            return
        } catch {
            if Task.isCancelled { return }
            lastError = error.localizedDescription
            if suggestion.isEmpty {
                onSuggestion?("")
            }
            Self.logger.error("completion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Instant history-based suggestion. Returns the suffix to append after
    /// `typed`, or empty when nothing matches. Most recent command wins.
    nonisolated static func localSuggestion(history: [String], typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { return "" }

        for cmd in history.reversed() {
            let candidate = cmd.trimmingCharacters(in: .whitespaces)
            guard candidate.count > typed.count, candidate.hasPrefix(typed) else { continue }
            let suffix = String(candidate.dropFirst(typed.count))
                .trimmingCharacters(in: .whitespaces)
            guard !suffix.isEmpty, suffix.count <= maxSuggestionChars else { continue }
            return suffix
        }
        return ""
    }

    /// Strip the already-typed prefix from a model response (models sometimes
    /// echo the full command) and keep it to a single line for ghost display.
    nonisolated static func suggestionSuffix(from raw: String, typed: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let text = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = text.hasPrefix(typed) ? String(text.dropFirst(typed.count)) : text
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the request but gives up after `requestTimeout` so a slow provider
    /// can't freeze the typing flow waiting for a suggestion.
    private static func runWithTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: requestTimeout)
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
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
            // Keep the context tiny — big prompts slow the TTFT on reasoning
            // models and defeat the whole point of inline completion.
            let history = context.recentCommands.suffix(3).joined(separator: "; ")
            contextLines.append("- Recent commands: \(history)")
        }
        if includeOutput, !context.recentOutput.isEmpty {
            let output = String(context.recentOutput.suffix(300))
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

/// Thread-safe accumulator for streaming suggestion chunks (onDelta fires on
/// a background thread while the UI state stays on the main actor).
private final class RawSuggestionBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        return text
    }
}
