//
//  CommandDecisionEngine.swift
//  Bonk
//
//  Command-side decision engine (renamed from AIReranker, phase 1).
//  Phase 1 composition: local deterministic ranking + the legacy LLM rerank
//  path. JevDecisionEngine / LayaDecisionEngine plug in here in phase 2
//  behind the DecisionEngine protocol — no caller changes.
//
//  Contract (unchanged): LLM NEVER creates candidates or invents CLI commands.
//  It ONLY reranks/scores candidates already present in the Candidate Pool.
//

import Foundation
import os

/// Command decision engine: scores and re-orders a fixed Candidate Pool.
final class CommandDecisionEngine: Sendable {
    static let shared = CommandDecisionEngine()

    private let logger = Logger(subsystem: "com.bonk", category: "CommandDecision")

    init() {}

    /// Picks the best candidate via a DecisionEngine (local / Jev / Laya).
    /// Returns the reordered pool with the winner first, or nil when the
    /// engine abstains (no selection), is unsure (confidence < decisionThreshold),
    /// or fails — in all those cases the caller keeps deterministic order.
    /// The engine NEVER invents candidates: selection is by stable id over
    /// the code-produced pool.
    /// Every judgment leaves a DecisionTrace (latency, winner, confidence,
    /// whether the order changed) — fire-and-forget, never on the hot path.
    func decideBest(
        candidates: [CommandCandidate],
        typed: String,
        state: String,
        engine: any DecisionEngine,
        decisionThreshold: Double,
        recorder: DecisionTraceRecorder = .shared
    ) async -> [CommandCandidate]? {
        guard candidates.count > 1 else { return nil }
        let pool = Array(candidates.prefix(5))
        let options = pool.map {
            DecisionOption(
                id: $0.id,
                label: $0.fullText ?? $0.displayText,
                localScore: $0.rawScore,
                isExactMatch: $0.isExactPrefixMatch
            )
        }
        let topConfidence = min(1.0, max(0.0, (pool.map(\.rawScore).max() ?? 0) / 100))
        let context = DecisionContext(
            localConfidence: topConfidence,
            decisionThreshold: decisionThreshold,
            facts: [
                "state": "User typed: \"\(typed)\"\n\(state)",
                "question": "Which candidate best continues the user's typed command?",
            ]
        )
        let start = ContinuousClock.now
        do {
            let decision = try await engine.choose(options: options, context: context)
            let elapsed = ContinuousClock.now - start
            let (seconds, attoseconds) = elapsed.components
            let latencyMs = Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
            let changedOrder = decision.selectedID.map { $0 != pool.first?.id } ?? false
            let trace = DecisionTrace(
                engine: engine.engineName,
                inputCount: options.count,
                originalTopID: pool.first?.id,
                selectedID: decision.selectedID,
                confidence: decision.confidence,
                confidenceSource: engine.choiceConfidenceSource,
                latencyMs: latencyMs,
                changedOrder: changedOrder
            )
            await recorder.record(trace)
            #if DEBUG
                print(
                    "[D-decide] engine=\(trace.engine) winner=\(trace.selectedID ?? "none") " +
                        "conf=\(trace.confidence) latMs=\(trace.latencyMs) changed=\(trace.changedOrder)"
                )
            #endif
            guard let winner = decision.selectedID,
                  decision.confidence >= decisionThreshold,
                  let idx = pool.firstIndex(where: { $0.id == winner })
            else { return nil }
            var reordered = [pool[idx]]
            reordered += pool.indices.filter { $0 != idx }.map { pool[$0] }
            reordered += candidates.dropFirst(pool.count)
            return reordered
        } catch {
            logger.debug("[CommandDecision] decideBest fell back to local order: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reranks existing candidates using LLM guidance, falling back to local order on timeout or failure.
    func rerank(
        candidates: [CommandCandidate],
        typed: String,
        snapshot: CommandContextSnapshot,
        provider: AIProviderConfig?,
        apiKey: String?
    ) async -> [CommandCandidate] {
        // Contract rule: If LLM is unavailable or candidate pool is trivial, return local ranking immediately.
        guard let provider, let apiKey, !apiKey.isEmpty || !provider.type.needsAPIKey, candidates.count > 1 else {
            return candidates
        }

        // Cap candidates to evaluate (max 5) to keep prompt small and parsing fast.
        let pool = Array(candidates.prefix(5))
        var candidateMap: [Int: CommandCandidate] = [:]
        var candidateListPrompt = ""
        for (idx, c) in pool.enumerated() {
            candidateMap[idx + 1] = c
            let text = c.suggestion.fullText ?? c.suggestion.displayText
            candidateListPrompt += "\(idx + 1). \(text)\n"
        }

        let prompt = """
        User typed: "\(typed)"
        Recent command/output: "\(snapshot.recentOutput.suffix(200).trimmingCharacters(in: .whitespacesAndNewlines))"

        Candidates:
        \(candidateListPrompt)
        Task: Rank the candidates above based on relevance to user intent. Output ONLY the numbers separated by commas (e.g. "1, 3, 2, 4"). Do not invent any new commands.
        """

        let messages: [LLMMessage] = [
            .system("You are a CLI ranker. Output only comma-separated indices of the given candidates."),
            .user(prompt)
        ]

        let llm = LLMProviderFactory.provider(for: provider, apiKey: apiKey, workload: .chat)

        do {
            // Hard timeout of 450ms for reranking so user typing never blocks
            let response = try await withTimeout(seconds: 0.45) {
                try await llm.chat(messages: messages, maxTokens: 32, disableReasoning: true)
            }

            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let indices = parseIndices(from: text, maxIndex: pool.count)
            guard !indices.isEmpty else {
                return candidates
            }

            // Reconstruct candidates according to LLM order
            var reranked: [CommandCandidate] = []
            var used = Set<Int>()

            for (position, index) in indices.enumerated() {
                if let candidate = candidateMap[index], !used.contains(index) {
                    used.insert(index)
                    // Apply rerank score bonus based on AI preference
                    let boostedScore = candidate.rawScore + Double(pool.count - position) * 5.0
                    reranked.append(CommandCandidate(
                        source: candidate.source,
                        authority: candidate.authority,
                        suggestion: candidate.suggestion,
                        rawScore: boostedScore,
                        isExactPrefixMatch: candidate.isExactPrefixMatch
                    ))
                }
            }

            // Append any candidates not explicitly mentioned by LLM in their original order
            for (idx, c) in pool.enumerated() {
                let id = idx + 1
                if !used.contains(id) {
                    reranked.append(c)
                }
            }

            // Append remaining candidates past prefix(5)
            if candidates.count > pool.count {
                reranked.append(contentsOf: candidates.dropFirst(pool.count))
            }

            return reranked
        } catch {
            logger.debug("[CommandDecision] Reranking skipped or timed out: \(error.localizedDescription)")
            return candidates
        }
    }

    /// Extract comma-separated integers from LLM response.
    private func parseIndices(from text: String, maxIndex: Int) -> [Int] {
        let pattern = #"\b([1-9][0-9]*)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        var indices: [Int] = []
        for match in matches {
            if let range = Range(match.range(at: 1), in: text),
               let num = Int(text[range]),
               num >= 1 && num <= maxIndex {
                indices.append(num)
            }
        }
        return indices
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }
}
