//
//  LogHighlightWorker.swift
//  Bonk
//

import Foundation
import os

final class LogHighlightWorker: @unchecked Sendable {
    static let shared = LogHighlightWorker()

    // userInitiated + smaller batch keeps interactive echo from starving behind 128-job backlog.
    // Bulk logs are still utility-like throughput, but interactive tiny chunks bypass this queue entirely (see TerminalEngineAdapter fast-path).
    private let queue = DispatchQueue(label: "com.bonk.logHighlight", qos: .userInitiated, attributes: [])
    private let batchSize = 32
    private struct Job: @unchecked Sendable {
        let id: UUID
        let text: String
        let patterns: [LogFieldPattern]
        let cacheKey: String
        let completion: @MainActor @Sendable (String) -> Void
    }
    private var pending: [Job] = []
    private var scheduled = false
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private let cacheLimit = 2000
    private let logger = Logger(subsystem: "com.bonk", category: "LogHighlightWorker")

    private init() {}

    // MARK: - Public

    func enqueue(text: String, host: HostItem? = nil, completion: @escaping @MainActor @Sendable (String) -> Void) {
        let patterns = LogSnapshot.patterns(for: host)
        let key = (host?.logProfile?.id.uuidString ?? "active") + "|" + text
        let job = Job(id: UUID(), text: text, patterns: patterns, cacheKey: key, completion: completion)
        lock.lock()
        pending.append(job)
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule {
            queue.async { [weak self] in self?.flush() }
        }
    }

    func enqueue(text: String, completion: @escaping @MainActor @Sendable (String) -> Void) {
        enqueue(text: text, host: nil, completion: completion)
    }

    func highlightSync(_ text: String, host: HostItem? = nil) -> String {
        LogColorizer.colorize(text, host: host)
    }

    // MARK: - Private

    private func flush() {
        var batch: [Job] = []
        lock.lock()
        let count = min(pending.count, batchSize)
        batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        let hasMore = !pending.isEmpty
        scheduled = hasMore
        lock.unlock()

        for job in batch {
            let highlighted = highlightIncremental(job.text, patterns: job.patterns, cacheKey: job.cacheKey)
            Task { @MainActor in job.completion(highlighted) }
        }
        if hasMore { queue.async { [weak self] in self?.flush() } }
    }

    private func highlightIncremental(_ text: String, patterns: [LogFieldPattern], cacheKey: String) -> String {
        lock.lock()
        if let cached = cache[cacheKey] { lock.unlock(); return cached }
        lock.unlock()

        let result = LogColorizer.colorize(text, patterns: patterns)

        lock.lock()
        if cache.count >= cacheLimit {
            let toRemove = cache.keys.prefix(cacheLimit / 5)
            for key in toRemove { cache.removeValue(forKey: key) }
        }
        cache[cacheKey] = result
        lock.unlock()
        return result
    }

    func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }
}
