//
//  AgentToolCacheTests.swift
//  BonkTests
//
//  Cache hits must skip the SSH round-trip; cache misses must execute.
//  Non-cacheable tools (run_command, skill, todo_write) always execute.
//

import Foundation
import Testing
@testable import Bonk

@Suite("Agent Tool Cache")
struct AgentToolCacheTests {

    // MARK: - Cache hit/miss

    @Test("A cache miss executes and stores the result")
    func missExecutesAndStores() async throws {
        let cache = AgentToolCache()
        var executions = 0
        let result = try await cache.lookupOrStore(
            toolName: ReadFileTool.toolName,
            arguments: ["path": "/etc/hosts"]
        ) {
            executions += 1
            return ("127.0.0.1 localhost", 0)
        }
        #expect(result.output == "127.0.0.1 localhost")
        #expect(result.exitCode == 0)
        #expect(executions == 1)
        #expect(cache.count == 1)
    }

    @Test("A cache hit returns the stored result without executing")
    func hitReturnsStoredResult() async throws {
        let cache = AgentToolCache()
        var executions = 0
        let keyArgs = ["path": "/etc/hosts"]

        _ = try await cache.lookupOrStore(
            toolName: ReadFileTool.toolName,
            arguments: keyArgs
        ) {
            executions += 1
            return ("127.0.0.1 localhost", 0)
        }
        let hit = try await cache.lookupOrStore(
            toolName: ReadFileTool.toolName,
            arguments: keyArgs
        ) {
            executions += 1
            return ("SHOULD NOT RUN", 0)
        }
        #expect(hit.output == "127.0.0.1 localhost")
        #expect(hit.exitCode == 0)
        #expect(executions == 1, "the cached result must not re-execute")
    }

    @Test("Different arguments for the same tool are cached separately")
    func differentArgsCachedSeparately() async throws {
        let cache = AgentToolCache()
        let first = try await cache.lookupOrStore(
            toolName: ListDirectoryTool.toolName,
            arguments: ["path": "/tmp"]
        ) { ("first", 0) }
        let second = try await cache.lookupOrStore(
            toolName: ListDirectoryTool.toolName,
            arguments: ["path": "/var"]
        ) { ("second", 0) }
        #expect(first.output == "first")
        #expect(second.output == "second")
        #expect(cache.count == 2)
    }

    @Test("The same tool with reordered arguments hits the same cache entry")
    func reorderedArgsHitSameEntry() async throws {
        let cache = AgentToolCache()
        let args1 = ["path": "/tmp", "flag": "a"]
        let args2 = ["flag": "a", "path": "/tmp"]
        let first = try await cache.lookupOrStore(
            toolName: ReadFileTool.toolName,
            arguments: args1
        ) { ("result-a", 0) }
        let second = try await cache.lookupOrStore(
            toolName: ReadFileTool.toolName,
            arguments: args2
        ) { ("result-b", 0) }
        #expect(first.output == "result-a")
        #expect(second.output == "result-a", "reordered args must hit the same entry")
        #expect(cache.count == 1)
    }

    // MARK: - Non-cacheable tools

    @Test("run_command is never cached")
    func runCommandNeverCached() async throws {
        let cache = AgentToolCache()
        #expect(!cache.isCacheable(toolName: BashRunTool.toolName))
        var executions = 0
        _ = try await cache.lookupOrStore(
            toolName: BashRunTool.toolName,
            arguments: ["command": "echo hi"]
        ) {
            executions += 1
            return ("hi", 0)
        }
        _ = try await cache.lookupOrStore(
            toolName: BashRunTool.toolName,
            arguments: ["command": "echo hi"]
        ) {
            executions += 1
            return ("hi", 0)
        }
        #expect(executions == 2, "run_command must execute every time")
        #expect(cache.count == 0, "nothing must be stored for run_command")
    }

    @Test("skill is never cached")
    func skillNeverCached() async throws {
        let cache = AgentToolCache()
        #expect(!cache.isCacheable(toolName: SkillTool.toolName))
    }

    @Test("todo_write is never cached")
    func todoWriteNeverCached() async throws {
        let cache = AgentToolCache()
        #expect(!cache.isCacheable(toolName: TodoWriteTool.toolName))
    }

    // MARK: - TTL eviction

    @Test("An expired entry is re-executed")
    func expiredEntryReExecuted() async throws {
        let cache = AgentToolCache()
        var executions = 0
        let _ = try await cache.lookupOrStore(
            toolName: InspectSystemTool.toolName,
            arguments: [:]
        ) {
            executions += 1
            return ("system info v1", 0)
        }
        #expect(cache.count == 1)

        // Manually expire by setting the entry's timestamp far in the past.
        // We cannot mutate the entry directly, so instead we verify behavior
        // through a second cache with a fabricated old entry is not possible
        // without exposing internals. Instead, we verify behavior through a
        // zero-TTL cache: any entry expires immediately.
        let zeroTTLCache = AgentToolCache(ttl: 0)
        var zeroExecutions = 0
        let first = try await zeroTTLCache.lookupOrStore(
            toolName: InspectSystemTool.toolName,
            arguments: [:]
        ) {
            zeroExecutions += 1
            return ("system info v1", 0)
        }
        let second = try await zeroTTLCache.lookupOrStore(
            toolName: InspectSystemTool.toolName,
            arguments: [:]
        ) {
            zeroExecutions += 1
            return ("system info v2", 0)
        }
        #expect(first.output == "system info v1")
        #expect(second.output == "system info v2", "with TTL=0, every call re-executes")
        #expect(zeroExecutions == 2)
    }

    // MARK: - Capacity eviction

    @Test("At capacity the oldest entry is evicted")
    func capacityEvictsOldest() async throws {
        let cache = AgentToolCache()
        // Fill to capacity using distinct keys.
        for i in 0..<AgentToolCache.maxEntries + 5 {
            _ = try await cache.lookupOrStore(
                toolName: ReadFileTool.toolName,
                arguments: ["path": "/file/\(i)"]
            ) { ("content-\(i)", 0) }
        }
        #expect(cache.count <= AgentToolCache.maxEntries, "the cache must not exceed its cap")
        // The earliest entries should have been evicted.
        let earliest = try await cache.lookupOrStore(
            toolName: ReadFileTool.toolName,
            arguments: ["path": "/file/0"]
        ) { ("should-not-happen", 0) }
        #expect(earliest.output == "should-not-happen", "the oldest entry was evicted")
    }

    // MARK: - removeAll

    @Test("removeAll clears the cache")
    func removeAllClears() async throws {
        let cache = AgentToolCache()
        _ = try await cache.lookupOrStore(
            toolName: ListDirectoryTool.toolName,
            arguments: ["path": "/tmp"]
        ) { ("tmp listing", 0) }
        #expect(cache.count == 1)
        cache.removeAll()
        #expect(cache.count == 0)
        // After removal, the same call executes again.
        var executions = 0
        _ = try await cache.lookupOrStore(
            toolName: ListDirectoryTool.toolName,
            arguments: ["path": "/tmp"]
        ) {
            executions += 1
            return ("tmp listing again", 0)
        }
        #expect(executions == 1, "after removeAll the entry executes again")
    }
}
