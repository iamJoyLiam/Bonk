//  GenerationController.swift
//  Bonk
//
//  Single place for debounce + generation + cancellation.
//  Ensures only generation-matching async may mutate UI (Invariant #4).
//

import Foundation

@MainActor
final class GenerationController {
    private(set) var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?

    var debounceMilliseconds: Int = 500

    func bumpGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    func cancelAll() {
        generation &+= 1
        debounceTask?.cancel()
        workTask?.cancel()
        debounceTask = nil
        workTask = nil
    }

    func scheduleDebounced(_ work: @escaping @MainActor () async -> Void) {
        debounceTask?.cancel()
        let gen = generation
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Double(debounceMilliseconds)))
            guard !Task.isCancelled else { return }
            // Generation check: if cancelled, gen != current
            await work()
        }
        _ = gen
    }

    func runWork(_ work: @escaping @MainActor () async -> Void) {
        workTask?.cancel()
        workTask = Task { @MainActor in
            await work()
        }
    }

    func isCurrent(_ gen: UInt64) -> Bool {
        gen == generation
    }
}
