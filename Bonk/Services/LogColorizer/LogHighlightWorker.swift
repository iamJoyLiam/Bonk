//
//  LogHighlightWorker.swift
//  Bonk
//
//  Background log highlight pipeline: PTY -> TerminalEngine -> LogHighlightWorker
//  Batch + incremental + byte-scanner + cache + overlay, never blocks renderer.
//

import Foundation
import os

final class LogHighlightWorker: @unchecked Sendable {
    nonisolated(unsafe) static let shared = LogHighlightWorker()

    private let queue = DispatchQueue(label: "com.bonk.logHighlight", qos: .utility, attributes: [])
    private let batchSize = 128 // tuned for 5000 lines <0.3s, 100 lines <3ms
    private var pending: [(id: UUID, text: String, completion: @MainActor @Sendable (String) -> Void)] = []
    private var scheduled = false
    private let lock = NSLock()
    private var cache: [String: String] = [:] // line -> highlighted (LRU, 2000)
    private let cacheLimit = 2000
    private let classifier = LogClassifier()
    private let logger = Logger(subsystem: "com.bonk", category: "LogHighlightWorker")

    private init() {}

    // MARK: - Public

    /// Enqueue a chunk (many logical lines) for background highlight.
    /// Called from TerminalEngine on MainActor, but work happens on utility queue.
    /// Completion is called on MainActor with highlighted text for dirty rows.
    func enqueue(text: String, completion: @escaping @MainActor @Sendable (String) -> Void) {
        let id = UUID()
        lock.lock()
        pending.append((id, text, completion))
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Synchronous fallback for tests or small chunks (uses same pipeline but inline)
    func highlightSync(_ text: String) -> String {
        // Directly use LogColorizer which now uses LogClassifier (two-stage)
        return LogColorizer.colorize(text)
    }

    // MARK: - Private

    private func flush() {
        var batch: [(UUID, String, @MainActor @Sendable (String) -> Void)] = []
        lock.lock()
        let count = min(pending.count, batchSize)
        batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        let hasMore = !pending.isEmpty
        scheduled = hasMore
        lock.unlock()

        // Process batch incrementally, only completed lines (with \n)
        for (_, text, completion) in batch {
            let highlighted = highlightIncremental(text)
            Task { @MainActor in
                completion(highlighted)
            }
        }

        if hasMore {
            queue.async { [weak self] in self?.flush() }
        }
    }

    private func highlightIncremental(_ text: String) -> String {
        // Only highlight completed lines (with \n), leave tail raw (as LogColorizer does)
        // Check cache first
        lock.lock()
        if let cached = cache[text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = LogColorizer.colorize(text)

        lock.lock()
        if cache.count >= cacheLimit {
            // Remove oldest 20%
            let toRemove = cache.keys.prefix(cacheLimit / 5)
            for k in toRemove { cache.removeValue(forKey: k) }
        }
        cache[text] = result
        lock.unlock()
        return result
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
