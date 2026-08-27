//
//  SuggestionEngine.swift
//  Bonk
//
//  Owns inline ghost lifecycle: debounce + generation + cache (Phase 6).
//  One place owns merge + cacheKey(12 segments) + generation; View only subscribes to Suggestion? and positions ghost.
//

import Combine
import Foundation
import os

struct Suggestion: Sendable, Equatable {
    let text: String          // raw suffix to insert
    let displayText: String   // ghost display (with leading space handling)
}

@MainActor
final class SuggestionEngine: ObservableObject {
    @Published var suggestion: Suggestion?
    @Published private(set) var isRequesting = false

    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var currentLLMTask: Task<Void, Never>?
    private var cache: [String: Suggestion] = [:]
    private var rejected: Set<String> = []
    private var activeKey: String?
    private static let cacheLimit = 200
    private static let cacheSeparator = "\u{001E}"
    private let logger = Logger(subsystem: "com.bonk", category: "SuggestionEngine")
    private let providerStore: AIProviderStore

    init(providerStore: AIProviderStore = .shared) {
        self.providerStore = providerStore
    }

    // MARK: - Public (small interface)

    func request(context: InlineCompletionContext) {
        generation &+= 1
        let gen = generation
        debounceTask?.cancel()
        currentLLMTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            await self.performRequest(context: context, generation: gen)
        }
    }

    func cancel() {
        generation &+= 1
        debounceTask?.cancel()
        currentLLMTask?.cancel()
        suggestion = nil
        activeKey = nil
        isRequesting = false
    }

    func accept() -> String {
        guard let s = suggestion else { return "" }
        let text = s.text
        if let key = activeKey { rejected.remove(key + "|" + text) }
        cancel()
        return text
    }

    func rejectCurrent() {
        guard let s = suggestion, let key = activeKey else { return }
        rejected.insert(key + "|" + s.text)
        cancel()
    }

    // MARK: - Deep impl (merge + cacheKey + generation)

    private func performRequest(context: InlineCompletionContext, generation: UInt64) async {
        let typed = context.inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return }
        guard let provider = providerStore.activeProvider else {
            logger.debug("[Suggestion] no active provider")
            return
        }
        let key = cacheKey(provider: provider, context: context, typed: typed)

        // 1. KnownWords instant (deterministic, from recentOutput)
        if let lastToken = typed.split(whereSeparator: { $0.isWhitespace }).last,
           let match = context.knownWords.first(where: { $0.lowercased().hasPrefix(lastToken.lowercased()) && $0.count > lastToken.count }),
           !isRejected(key: key, suffix: String(match.dropFirst(lastToken.count))) {
            let suffix = String(match.dropFirst(lastToken.count))
            let display = Self.displaySuffix(suffix, typed: typed)
            let sug = Suggestion(text: suffix, displayText: display)
            if generation == self.generation {
                suggestion = sug
                activeKey = key
                cache[key] = sug
            }
        }

        // 2. Cache hit (12-segment key)
        if let cached = cache[key], !isRejected(key: key, suffix: cached.text) {
            if generation == self.generation {
                suggestion = cached
                activeKey = key
            }
        }

        // 3. Local history instant
        if !context.recentCommands.isEmpty {
            let local = Self.localSuggestion(history: context.recentCommands, typed: typed)
            if !local.isEmpty, !isRejected(key: key, suffix: local) {
                let display = Self.displaySuffix(local, typed: typed)
                let sug = Suggestion(text: local, displayText: display)
                if generation == self.generation {
                    suggestion = sug
                    activeKey = key
                }
            }
        }

        // 4. LLM stream (3s timeout, generation guard) — delegates to InlineCompletionService for now
        // Keep isRequesting true while LLM is in flight; InlineCompletionService owns the actual stream.
        isRequesting = true
        currentLLMTask = Task { [weak self] in
            guard let self else { return }
            // Delegate to InlineCompletionService (single LLM path) but map to Suggestion
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                InlineCompletionService.shared.request(context: context) { [weak self] text in
                    guard let self else { cont.resume(); return }
                    guard generation == self.generation else { cont.resume(); return }
                    let suffix: String
                    if text.hasPrefix(typed) { suffix = String(text.dropFirst(typed.count)) }
                    else { suffix = text }
                    let clipped = String(suffix.prefix(InlineCompletionService.maxSuggestionChars))
                    guard !clipped.isEmpty, !self.isRejected(key: key, suffix: clipped) else { cont.resume(); return }
                    let display = Self.displaySuffix(clipped, typed: typed)
                    let sug = Suggestion(text: clipped, displayText: display)
                    self.suggestion = sug
                    self.activeKey = key
                    self.cache[key] = sug
                    self.trimCache()
                    cont.resume()
                }
                // Also complete after 3s if LLM doesn't return (Warp-style fast or nothing)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: InlineCompletionService.requestTimeout)
                    if self?.isRequesting == true, generation == self?.generation {
                        self?.isRequesting = false
                    }
                    // Ensure continuation resumed if not already
                }
            }
            if generation == self.generation { self.isRequesting = false }
        }
    }

    // MARK: - Helpers

    private func cacheKey(provider: AIProviderConfig, context: InlineCompletionContext, typed: String) -> String {
        // 12 segments joined by U001E (see InlineCompletionService.cacheKey)
        let parts = [
            "v2",
            provider.id.uuidString,
            provider.endpoint,
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
        return parts.map { $0.replacingOccurrences(of: Self.cacheSeparator, with: " ") }.joined(separator: Self.cacheSeparator)
    }

    private func isRejected(key: String, suffix: String) -> Bool {
        rejected.contains(key + "|" + suffix)
    }

    private func trimCache() {
        if cache.count > Self.cacheLimit {
            let oldest = cache.keys.prefix(cache.count - Self.cacheLimit)
            for k in oldest { cache.removeValue(forKey: k) }
        }
    }

    nonisolated static func displaySuffix(_ suffix: String, typed: String) -> String {
        if typed.hasSuffix(" ") { return suffix.hasPrefix(" ") ? suffix : " " + suffix }
        return suffix.hasPrefix(" ") ? String(suffix.dropFirst()) : suffix
    }

    nonisolated static func localSuggestion(history: [String], typed: String) -> String {
        // Most recent command that has typed as prefix and is longer
        for cmd in history.reversed() {
            if cmd.hasPrefix(typed), cmd.count > typed.count {
                return String(cmd.dropFirst(typed.count))
            }
            // also try case-insensitive prefix
            if cmd.lowercased().hasPrefix(typed.lowercased()), cmd.count > typed.count {
                // preserve original casing from history
                let idx = cmd.index(cmd.startIndex, offsetBy: typed.count)
                return String(cmd[idx...])
            }
        }
        return ""
    }
}
