//
//  AgentToolCache.swift
//  Bonk
//
//  Thread-safe cache for idempotent, read-only tool results.
//
//  Only read-only tools are eligible: read_file, list_dir, inspect_system,
//  search_history. run_command, skill, todo_write are never cached because
//  they may have side effects or are the model's own state.
//
//  Entries expire after a TTL; when the cap is reached the oldest entry is
//  evicted. A cache hit skips the SSH round-trip entirely.
//

import Foundation
import os

/// How long a cache entry is considered fresh.
private let cacheTTL: TimeInterval = 5 * 60 // 5 minutes

/// Maximum number of entries before the oldest is evicted.
private let cacheMaxEntries = 100

/// Read-only tool names eligible for caching.
///
/// These tools have no side effects: reading them twice returns the same
/// result (within the TTL). run_command may mutate state, skill reads a
/// host file chosen by the model, and todo_write is the model's own state —
/// none of them are safe to cache.
private let cacheableToolNames: Set<String> = [
    ReadFileTool.toolName,
    ListDirectoryTool.toolName,
    InspectSystemTool.toolName,
    SearchHistoryTool.toolName,
]

/// Result of one cached tool execution.
private struct CacheEntry {
    let output: String
    let exitCode: Int32
    let timestamp: Date
}

/// Build a cache key from a tool name and its arguments.
///
/// The key is deterministic: same tool + same normalized arguments = same
/// key, regardless of argument ordering or cosmetic whitespace differences.
private func cacheKey(tool: String, arguments: [String: String]) -> String {
    let argsKey = arguments.sorted(by: { $0.key < $1.key })
        .map { "\($0.key)=\(CommandNormalizer.normalizedKey($0.value))" }
        .joined(separator: " ")
    return argsKey.isEmpty ? tool : "\(tool) \(argsKey)"
}

/// Thread-safe cache for idempotent, read-only tool results.
final class AgentToolCache: @unchecked Sendable {
    /// Maximum number of entries before the oldest is evicted.
    static let maxEntries = cacheMaxEntries

    /// How long an entry is considered fresh (configurable for tests).
    let ttl: TimeInterval

    private let lock = OSAllocatedUnfairLock<[String: CacheEntry]>(uncheckedState: [:])

    init(ttl: TimeInterval = cacheTTL) {
        self.ttl = ttl
    }

    /// Look up a cached result by key. Returns nil when absent or expired.
    func lookup(key: String) -> (output: String, exitCode: Int32)? {
        lock.withLock { storage in
            guard let entry = storage[key],
                  Date().timeIntervalSince(entry.timestamp) < self.ttl
            else { return nil }
            return (entry.output, entry.exitCode)
        }
    }

    /// Store a result in the cache. Evicts the oldest entry when at capacity.
    func store(key: String, output: String, exitCode: Int32) {
        lock.withLock { storage in
            if storage.count >= cacheMaxEntries, storage[key] == nil {
                if let oldest = storage.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                    storage.removeValue(forKey: oldest)
                }
            }
            storage[key] = CacheEntry(output: output, exitCode: exitCode, timestamp: Date())
        }
    }

    /// Whether a tool name is eligible for caching.
    func isCacheable(toolName: String) -> Bool {
        cacheableToolNames.contains(toolName)
    }

    /// Look up a cached result, or execute and store if absent.
    ///
    /// Only caches when `toolName` is eligible; otherwise `execute` is always
    /// called and nothing is stored.
    func lookupOrStore(
        toolName: String,
        arguments: [String: String],
        execute: () async throws -> (output: String, exitCode: Int32)
    ) async rethrows -> (output: String, exitCode: Int32) {
        guard isCacheable(toolName: toolName) else {
            return try await execute()
        }
        let key = cacheKey(tool: toolName, arguments: arguments)
        if let hit = lookup(key: key) {
            return hit
        }
        let result = try await execute()
        store(key: key, output: result.output, exitCode: result.exitCode)
        return result
    }

    /// Number of entries currently in the cache.
    var count: Int {
        lock.withLock { storage in
            storage.count
        }
    }

    /// Remove all entries.
    func removeAll() {
        lock.withLock { storage in
            storage.removeAll()
        }
    }

    private var storage: [String: CacheEntry] = [:]
}
