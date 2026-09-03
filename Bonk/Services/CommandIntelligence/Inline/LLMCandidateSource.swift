//  LLMCandidateSource.swift
//  Bonk
//
//  LLM as one CandidateSource — not a serial stage.
//  Wraps LLMProviderFactory + prompt + streaming + timeout + normalize.
//  P0: scaffolding delegates to InlineCompletionService's proven streaming for parity, but via protocol.
//

import Foundation

final class LLMCandidateSource: InlineCandidateSource, @unchecked Sendable {
    let name = "llm"
    private let providerStore: AIProviderStore
    private let cache: InlineSuggestionCache?
    private let maxTokens = SuggestionFormatter.maxSuggestionTokens
    private let maxChars = SuggestionFormatter.maxSuggestionChars
    private let requestTimeout: Duration = .seconds(3)

    @MainActor init(providerStore: AIProviderStore, cache: InlineSuggestionCache? = nil) {
        self.providerStore = providerStore
        self.cache = cache
    }

    func suggestion(for snapshot: CommandContextSnapshot, typed: String) async -> Suggestion? {
        // Single-shot not used — pipeline uses stream() for progressive ghost
        _ = snapshot; _ = typed
        return nil
    }

    /// Streaming LLM — progressive ghost, timeout, rejection, cache. Generation guard is owned by Pipeline.
    func stream(
        for snapshot: CommandContextSnapshot,
        typed: String,
        generation _: UInt64,
        cacheKey: String,
        onSuggestion: @escaping @MainActor @Sendable (String) -> Void
    ) async {
        guard let (provider, apiKey) = await resolveProvider(snapshot: snapshot) else { return }
        let prompt = await MainActor.run { InlinePromptBuilder.buildPrompt(snapshot: snapshot) }
        let cache = self.cache
        let buffer = LLMRawBuffer()
        let llm = LLMProviderFactory.provider(for: provider, apiKey: apiKey, workload: .inlineCompletion)
        do {
            let response = try await Self.runWithTimeout(timeout: requestTimeout) {
                var result = ""
                for try await event in llm.stream(
                    messages: [.system(prompt), .user(typed)],
                    maxTokens: self.maxTokens,
                    disableReasoning: true
                ) {
                    guard case let .textDelta(delta) = event else { continue }
                    result += delta
                    let candidate = SuggestionFormatter.displaySuffix(
                        SuggestionFormatter.suggestionSuffix(from: buffer.append(delta), typed: typed),
                        typed: typed
                    )
                    guard !candidate.isEmpty, candidate.count <= self.maxChars else { continue }
                    let displayCandidate = candidate
                    // Rejection check on main actor
                    let rejected = await MainActor.run { cache?.isRejected(key: cacheKey, suffix: displayCandidate) ?? false }
                    guard !rejected else { continue }
                    await onSuggestion(displayCandidate)
                }
                return result
            }
            guard !Task.isCancelled else { return }
            let suffix = SuggestionFormatter.displaySuffix(
                SuggestionFormatter.suggestionSuffix(from: response, typed: typed),
                typed: typed
            )
            guard !suffix.isEmpty else { return }
            let rejected = await MainActor.run { cache?.isRejected(key: cacheKey, suffix: suffix) ?? false }
            guard !rejected else { return }
            await onSuggestion(suffix)
            await MainActor.run { cache?.store(suffix: suffix, for: cacheKey) }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
        }
    }

    @MainActor private func resolveProvider(snapshot: CommandContextSnapshot) -> (AIProviderConfig, String)? {
        let defaults = UserDefaults.standard
        let overrideID = defaults.string(forKey: "ai_inline_provider_id") ?? ""
        let provider: AIProviderConfig?
        if !overrideID.isEmpty {
            provider = providerStore.providers.first { $0.id.uuidString == overrideID }
        } else {
            provider = ModelRouter.shared.provider(for: IntelligenceTask.inlineCompletion, snapshot: snapshot) ?? providerStore.activeProvider
        }
        guard var p = provider else { return nil }
        if let inlineModel = defaults.string(forKey: "ai_inline_model"),
           !inlineModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p.model = inlineModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = p.apiKey
        guard !p.type.needsAPIKey || !key.isEmpty else { return nil }
        return (p, key)
    }

    private static func runWithTimeout<T: Sendable>(timeout: Duration, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers (delegated for parity)

    func normalize(_ raw: String) -> String {
        SuggestionFormatter.normalize(raw)
    }

    func displaySuffix(_ suffix: String, typed: String) -> String {
        SuggestionFormatter.displaySuffix(suffix, typed: typed)
    }
}

private final class LLMRawBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        return text
    }
}
