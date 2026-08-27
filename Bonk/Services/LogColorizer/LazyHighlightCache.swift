//
//  LazyHighlightCache.swift
//  Bonk — Final Architecture: Lazy Highlight Cache
//
//  Only computes highlights for viewport/history that is actually needed.
//

import Foundation

final class LazyHighlightCache: @unchecked Sendable {
    struct Entry {
        let line: String
        let spans: [HighlightSpan]
        let timestamp: Date
    }
    private var store: [Int: Entry] = [:] // row -> Entry
    private let lock = NSLock()
    private let limit = 5000 // keep last 5000 rows

    func store(row: Int, line: String, spans: [HighlightSpan]) {
        lock.lock()
        defer { lock.unlock() }
        if store.count >= limit {
            let oldest = store.keys.sorted().prefix(limit/5)
            for k in oldest { store.removeValue(forKey: k) }
        }
        store[row] = Entry(line: line, spans: spans, timestamp: Date())
    }

    func get(row: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return store[row]
    }

    func clear() {
        lock.lock()
        store.removeAll()
        lock.unlock()
    }
}
