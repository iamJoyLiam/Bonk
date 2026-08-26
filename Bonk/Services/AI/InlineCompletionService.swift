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
import SwiftData

/// Snapshot of terminal state used as context for a completion request.
/// Fetched lazily at request time, so it always reflects the current line.
struct InlineCompletionContext {
    /// Pure user-typed text (no prompt prefix), from the session input buffer.
    var inputBuffer: String
    /// Stable host/session scope. Prevents suggestions leaking across hosts.
    var hostKey: String?
    var currentDirectory: String?
    var shell: String?
    var recentCommands: [String]
    var recentOutput: String
    var lastExitCode: Int?
    /// Tool-agnostic identifiers extracted from recent output (container
    /// names, file names, branches, pods, ...) — no tool-specific parsing.
    var knownWords: [String]
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
    private var requestGeneration = 0
    /// Recent successful suggestions keyed by "provider|typed", so repeating
    /// the same prefix shows instantly without a model round-trip.
    private var suggestionCache: [String: String] = [:]
    private static let suggestionCacheLimit = 200
    private var modelContext: ModelContext?
    private var persistentCache: [String: InlineSuggestionRecord] = [:]
    private static let persistentCacheLimit = 500
    private static let persistentCacheTTL: TimeInterval = 7 * 24 * 60 * 60
    /// Key of the suggestion currently on screen, for accept/reject feedback.
    private var activeKey: String?
    /// Suffixes rejected in this session — never re-suggest them.
    private var rejectedSuggestions: Set<String> = []

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

    /// Attach the app's SwiftData context so habit suggestions persist.
    func attachModelContext(_ context: ModelContext) {
        modelContext = context
        loadPersistentCache()
    }

    private func loadPersistentCache() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<InlineSuggestionRecord>()
        guard let records = try? modelContext.fetch(descriptor) else { return }
        let cutoff = Date().addingTimeInterval(-Self.persistentCacheTTL)
        let active = records.filter { $0.lastUsedAt >= cutoff }
        for record in records where record.lastUsedAt < cutoff {
            modelContext.delete(record)
        }
        persistentCache = Dictionary(uniqueKeysWithValues: active.map { ($0.key, $0) })
        trimPersistentCache()
        try? modelContext.save()
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
        requestGeneration += 1
        let generation = requestGeneration
        suggestion = ""
        lastError = nil

        guard isEnabled else { return }
        guard let (provider, apiKey) = resolveProvider() else { return }
        let rawTyped = context.inputBuffer
        let typed = rawTyped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return }
        let cacheKey = Self.cacheKey(provider: provider, context: context, typed: typed)

        // Deterministic local completion: if the tail token is a prefix of a
        // name the user just saw in the output, show it immediately while the
        // model still gets a chance to replace it with a better continuation.
        if includeTerminalOutput,
           let lastToken = typed.split(whereSeparator: { $0.isWhitespace }).last,
           let match = context.knownWords
               .filter({ $0.lowercased().hasPrefix(lastToken.lowercased()) && $0.count > lastToken.count })
               .sorted(by: { $0.count < $1.count })
               .first
        {
            let suffix = String(match.dropFirst(lastToken.count))
            let display = Self.displaySuffix(suffix, typed: typed)
            suggestion = display
            activeKey = cacheKey
            onSuggestion?(display)
        }

        // Instant repeat: serve cached suffix from same host/model/context.
        if let cached = suggestionCache[cacheKey] ?? persistentCache[cacheKey]?.suffix {
            guard !isRejected(cacheKey: cacheKey, suffix: cached) else { return }
            let display = Self.displaySuffix(cached, typed: typed)
            suggestion = display
            activeKey = cacheKey
            onSuggestion?(display)
            return
        }

        isRequesting = true
        let prompt = Self.buildPrompt(
            context: context,
            includeOutput: includeTerminalOutput,
            includeHistory: includeCommandHistory,
            includeEnv: includeEnvironmentInfo,
            approvedExamples: approvedExamples(for: context.hostKey ?? "")
        )

        // Instant local fallback — history is the fastest, most accurate
        // predictor for commands the user has already run. Gated by the same
        // setting that controls history in the model prompt.
        if includeCommandHistory, !context.recentCommands.isEmpty {
            let local = Self.localSuggestion(history: context.recentCommands, typed: typed)
            if !local.isEmpty {
                let display = Self.displaySuffix(local, typed: typed)
                suggestion = display
                activeKey = cacheKey
                onSuggestion?(display)
            }
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.streamModelSuggestion(
                provider: provider, apiKey: apiKey,
                prompt: prompt, typed: typed, generation: generation,
                cacheKey: cacheKey,
                onSuggestion: onSuggestion
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
        generation: Int,
        cacheKey: String,
        onSuggestion: (@MainActor @Sendable (String) -> Void)?
    ) async {
        defer { isRequesting = false }
        let buffer = RawSuggestionBuffer()
        let llm = LLMProviderFactory.provider(
            for: provider, apiKey: apiKey, workload: .inlineCompletion
        )
        do {
            let response = try await Self.runWithTimeout {
                var result = ""
                for try await event in llm.stream(
                    messages: [
                        .system(prompt),
                        .user(typed),
                    ],
                    maxTokens: Self.maxSuggestionTokens,
                    disableReasoning: true
                ) {
                    guard case let .textDelta(delta) = event else { continue }
                    result += delta

                    // Show the ghost as soon as the first tokens arrive —
                    // waiting for the full stream makes slow providers feel
                    // broken. `suggestion` updates so Tab works mid-stream.
                    let candidate = Self.displaySuffix(
                        Self.suggestionSuffix(from: buffer.append(delta), typed: typed),
                        typed: typed
                    )
                    guard !candidate.isEmpty,
                          candidate.count <= Self.maxSuggestionChars
                    else { continue }
                    let displayCandidate = candidate
                    Task { @MainActor [weak self] in
                        guard let self, self.requestGeneration == generation else { return }
                        guard !self.isRejected(cacheKey: cacheKey, suffix: displayCandidate) else { return }
                        self.suggestion = displayCandidate
                        self.activeKey = cacheKey
                        onSuggestion?(displayCandidate)
                    }
                }
                return result
            }
            guard !Task.isCancelled else { return }
            guard generation == requestGeneration else { return }
            let suffix = Self.displaySuffix(
                Self.suggestionSuffix(from: response, typed: typed),
                typed: typed
            )
            if !suffix.isEmpty {
                guard !isRejected(cacheKey: cacheKey, suffix: suffix) else { return }
                suggestion = suffix
                activeKey = cacheKey
                rememberSuggestion(suffix, for: cacheKey)
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

    private func rememberSuggestion(_ suffix: String, for key: String) {
        suggestionCache[key] = suffix
        if suggestionCache.count > Self.suggestionCacheLimit {
            suggestionCache.removeAll()
        }
        if let existing = persistentCache[key] {
            existing.suffix = suffix
            existing.lastUsedAt = Date()
        } else if let modelContext {
            let record = InlineSuggestionRecord(key: key, suffix: suffix)
            modelContext.insert(record)
            persistentCache[key] = record
        }
        trimPersistentCache()
        try? modelContext?.save()
    }

    private func trimPersistentCache() {
        guard persistentCache.count > Self.persistentCacheLimit else { return }
        let sorted = persistentCache.values.sorted { $0.lastUsedAt < $1.lastUsedAt }
        let overflow = sorted.prefix(persistentCache.count - Self.persistentCacheLimit)
        for record in overflow {
            persistentCache.removeValue(forKey: record.key)
            modelContext?.delete(record)
        }
    }

    /// Instant history-based suggestion. Returns the suffix to append after
    /// `typed`, or empty when nothing matches. Most recent command wins.
    nonisolated static func localSuggestion(history: [String], typed: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { return "" }

        for cmd in history.reversed() {
            let candidate = cmd.trimmingCharacters(in: .whitespaces)
            guard candidate.count > typed.count else { continue }

            guard candidate.lowercased().hasPrefix(typed.lowercased()) else { continue }
            let suffix = String(candidate.dropFirst(typed.count))
            let normalized = preserveLeadingSeparator(suffix)
            let core = normalized.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty, core.count <= maxSuggestionChars else { continue }
            return normalized
        }
        return ""
    }

    /// Strip the already-typed prefix from a model response (models sometimes
    /// echo the full command) and keep it to a single line for ghost display.
    nonisolated static func suggestionSuffix(from raw: String, typed: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let text = firstLine.trimmingCharacters(in: .newlines)
        // Models often echo part of the typed command. Strip the longest
        // overlap between the end of `typed` and the start of the response,
        // so "docker log" + "logs -f" → "s -f" instead of "logs -f".
        var overlap = 0
        let maxOverlap = min(typed.count, text.count)
        if maxOverlap > 0 {
            for length in stride(from: maxOverlap, through: 1, by: -1)
            where text.hasPrefix(typed.suffix(length)) {
                overlap = length
                break
            }
        }
        let suffix = overlap > 0 ? String(text.dropFirst(overlap)) : text
        return Self.preserveLeadingSeparator(suffix)
    }

    /// Turn model/local output into exact text to append after cursor.
    /// Leading separator survives; token-boundary fallback handles models
    /// that omit it.
    nonisolated static func displaySuffix(_ raw: String, typed: String) -> String {
        let suffix = preserveLeadingSeparator(raw)
        guard !suffix.isEmpty else { return "" }

        let hasExplicitSeparator = suffix.first?.isWhitespace == true
        let core = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return "" }

        if hasExplicitSeparator || typed.last?.isWhitespace == true {
            return hasExplicitSeparator ? " " + core : core
        }

        if shouldInsertTokenSeparator(typed: typed, suffix: core) {
            return " " + core
        }
        return core
    }

    /// Stable cache key. Includes model route and terminal scope/context so
    /// stale suggestions do not cross hosts or model changes.
    nonisolated static func cacheKey(
        provider: AIProviderConfig,
        context: InlineCompletionContext,
        typed: String
    ) -> String {
        [
            "v2",
            provider.id.uuidString,
            AIProviderNetworking.baseEndpoint(provider.endpoint),
            provider.model,
            provider.protocolType.rawValue,
            context.hostKey ?? "",
            context.currentDirectory ?? "",
            context.shell ?? "",
            typed,
            context.lastExitCode.map(String.init) ?? "",
            context.recentCommands.suffix(5).joined(separator: "\u{1F}"),
            String(context.recentOutput.suffix(160)),
        ]
        .map { $0.replacingOccurrences(of: Self.cacheSeparator, with: " ") }
        .joined(separator: Self.cacheSeparator)
    }

    private nonisolated static let cacheSeparator = "\u{1E}"

    private nonisolated static func preserveLeadingSeparator(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .newlines)
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        let hasLeadingSeparator = text.first?.isWhitespace == true
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return hasLeadingSeparator ? " " + text : text
    }

    private nonisolated static func shouldInsertTokenSeparator(
        typed: String,
        suffix: String
    ) -> Bool {
        guard typed.last?.isWhitespace == false else { return false }
        guard let first = suffix.first,
              first.isLetter || first.isNumber || first == "-" || first == "/" || first == "$"
        else { return false }

        // Current token continuation: `docker p` + `s`, `git st` + `atus`.
        let tokens = typed.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 1 else { return false }

        // Shell assignment/expansion/path continuation must not gain a space.
        if let last = typed.last, "=/:.$~\\".contains(last) {
            return false
        }
        if typed.contains("=") {
            return false
        }
        return true
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
        if let key = activeKey, let record = persistentCache[key] {
            record.acceptCount += 1
            record.lastUsedAt = Date()
            try? modelContext?.save()
        }
        suggestion = ""
        activeKey = nil
        currentTask?.cancel()
        isRequesting = false
        return result
    }

    /// Cancel any request and clear the suggestion (Esc / any other input).
    func dismiss(rejected: Bool = false) {
        if rejected, let key = activeKey, !suggestion.isEmpty {
            if let record = persistentCache[key] {
                record.rejectCount += 1
                try? modelContext?.save()
            }
            rejectedSuggestions.insert(key + "|" + suggestion)
        }
        currentTask?.cancel()
        currentTask = nil
        suggestion = ""
        activeKey = nil
        isRequesting = false
    }

    private func isRejected(cacheKey: String, suffix: String) -> Bool {
        rejectedSuggestions.contains(cacheKey + "|" + suffix)
    }

    /// Few-shot examples from completions the user actually accepted, most
    /// approved first — cheap retrieval without a vector index.
    private func approvedExamples(for hostKey: String) -> [String] {
        return persistentCache.values
            .filter {
                guard $0.acceptCount > 0 else { return false }
                let fields = $0.key.components(separatedBy: Self.cacheSeparator)
                return fields.count > 8 && fields[5] == hostKey
            }
            .sorted { $0.acceptCount > $1.acceptCount }
            .prefix(5)
            .map { record in
                let fields = record.key.components(separatedBy: Self.cacheSeparator)
                let typed = fields.count > 8 ? fields[8] : ""
                return "\(typed) → \(record.suffix)"
            }
    }

    // MARK: - Provider

    private func resolveProvider() -> (AIProviderConfig, String)? {
        // Inline hints must be fast — allow a dedicated fast provider instead
        // of whatever the main chat uses.
        let overrideID = defaults.string(forKey: "ai_inline_provider_id") ?? ""
        let provider: AIProviderConfig?
        if !overrideID.isEmpty {
            provider = providerStore.providers.first { $0.id.uuidString == overrideID }
        } else {
            provider = providerStore.activeProvider
        }
        guard var provider else { return nil }
        if let inlineModel = defaults.string(forKey: "ai_inline_model"),
           !inlineModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            provider.model = inlineModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = provider.apiKey
        guard !provider.type.needsAPIKey || !key.isEmpty else { return nil }
        return (provider, key)
    }

    // MARK: - Prompt

    /// Build the system prompt for a completion request.
    /// Pure function so it is unit-testable.
    static func buildPrompt(
        context: InlineCompletionContext,
        includeOutput: Bool,
        includeHistory: Bool,
        includeEnv: Bool,
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
        if includeEnv, let cwd = context.currentDirectory, !cwd.isEmpty {
            contextLines.append("- Working directory: \(cwd)")
        }
        if let shell = context.shell, !shell.isEmpty {
            contextLines.append("- Shell: \(shell)")
        }
        if let exitCode = context.lastExitCode {
            contextLines.append("- Last command exit code: \(exitCode)")
        }
        if includeHistory, !context.recentCommands.isEmpty {
            // Keep the context tiny — big prompts slow the TTFT on reasoning
            // models and defeat the whole point of inline completion.
            let history = context.recentCommands.suffix(5).joined(separator: "; ")
            contextLines.append("- Recent commands: \(history)")
        }
        if !approvedExamples.isEmpty {
            contextLines.append(
                "- User-approved completions (prefix → suffix):\n"
                    + approvedExamples.joined(separator: "\n")
            )
        }
        if includeOutput, !context.recentOutput.isEmpty {
            let output = stripANSI(String(context.recentOutput.suffix(600)))
            contextLines.append("- Recent terminal output:\n\(output)")
        }
        if includeOutput, !context.knownWords.isEmpty {
            let words = context.knownWords.prefix(30).joined(separator: ", ")
            contextLines.append("- Likely identifiers/names from recent output: \(words)")
        }
        if !contextLines.isEmpty {
            parts.append("Context:\n" + contextLines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    /// Generic word extraction from terminal output: keeps word-like tokens
    /// that could be names (letters + numbers/path chars), drops flags, pure
    /// numbers and common noise. Works for docker, ls, git, kubectl, systemctl…
    nonisolated static func extractKnownWords(from output: String, limit: Int = 30) -> [String] {
        let cleaned = stripANSI(output)
        let tokens = cleaned.split { character in
            !(character.isLetter || character.isNumber || "._/-".contains(character))
        }

        var seen = Set<String>()
        var result: [String] = []
        for token in tokens {
            let word = String(token)
            guard word.count >= 2, word.count <= 40,
                  word.rangeOfCharacter(from: .letters) != nil,
                  !word.hasPrefix("-"),
                  !noiseWords.contains(word.lowercased()),
                  seen.insert(word.lowercased()).inserted
            else { continue }
            result.append(word)
            if result.count >= limit { break }
        }
        return result
    }

    private nonisolated static let noiseWords: Set<String> = [
        "usage", "command", "name", "names", "total", "type", "mode", "size",
        "flags", "true", "false", "root", "docker", "ps", "logs", "run", "exec",
        "error", "info", "help", "status", "up", "down", "created", "ports",
    ]

    private nonisolated static let stripANSIRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\x1B(?:\[[0-9;?]*[a-zA-Z]|\][^\x07\x1B]*(?:\x07|\x1B\\))"#
    )

    /// Remove CSI/OSC escapes so prompt tokens are not wasted on color codes.
    nonisolated private static func stripANSI(_ text: String) -> String {
        guard let regex = stripANSIRegex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Output Normalization

    private nonisolated static let promptLeftoverRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^[>\$#%❯➜]\s+"#
    )

    /// Clean a model response into a single-line suggestion.
    /// Pure function so it is unit-testable.
    nonisolated static func normalize(_ raw: String) -> String {
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
        if let regex = promptLeftoverRegex,
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return "" }
        return text
    }

    // MARK: - Prompt Prefix Stripping

    private nonisolated static let commandTextRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[>%$#❯➜]\s+(\S.*)$"#
    )

    /// Extract the command part from a terminal line that may contain a shell
    /// prompt prefix (e.g. `user@host:~$ docker ru` → `docker ru`).
    /// Matches the first prompt symbol followed by whitespace and a command.
    /// Pure function so it is unit-testable.
    static func commandText(from line: String) -> String? {
        guard let regex = commandTextRegex else { return nil }
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
