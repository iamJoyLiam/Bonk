//
//  SuggestionEngine.swift
//  Bonk
//
//  Owns inline ghost lifecycle: debounce + generation + cache (Phase 6).
//  View only subscribes to Suggestion? and positions ghost.
//

import Combine
import Foundation

struct Suggestion: Sendable, Equatable {
    let text: String
    let displayText: String
}

@MainActor
final class SuggestionEngine: ObservableObject {
    @Published var suggestion: Suggestion?
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?

    func request(for context: String) {
        generation &+= 1
        let gen = generation
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self?.generation == gen else { return }
            // Placeholder: knownWords -> cache -> LLM stream
            self?.suggestion = Suggestion(text: context, displayText: context)
        }
    }

    func cancel() {
        generation &+= 1
        debounceTask?.cancel()
        suggestion = nil
    }
}
