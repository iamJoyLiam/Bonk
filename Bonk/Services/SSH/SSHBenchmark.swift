//
//  SSHBenchmark.swift
//  Bonk — VNext M6 Benchmark Harness
//
//  Nine tests from ssh-vnext-architecture.md §15 M6 table.
//  Measures Native vs Compatibility on the same endpoint (modern server where both work).
//  For legacy-only hosts, only Compatibility column will have data.
//
//  Usage (Debug, on a Mac with access to test hosts):
//    let runner = SSHBenchmarkRunner()
//    let result = await runner.runAll(host: host, iterations: 3)
//    print(result.markdownRow)
//  Or run via XCTest `SSHBenchmarkTests` (see below).
//
//  Note: ConnectInteractive/Throughput/Exec tests need a live SSH server.
//  This file only provides the harness; fill the M6 table after real-device runs.
//

import Foundation
import os.log

// MARK: - Result Model

public struct SSHBenchmarkCaseResult: Sendable {
    public var nativeMs: Double?
    public var compatMs: Double?
    public var nativeExtra: String? // e.g. "CPU 12% Mem 80MB"
    public var compatExtra: String?
}

public struct SSHBenchmarkResult: Sendable {
    public var host: String
    public var port: Int
    public var date: Date
    public var connectionEstablishment = SSHBenchmarkCaseResult()
    public var interactiveLatency = SSHBenchmarkCaseResult()
    public var throughput1MB = SSHBenchmarkCaseResult()
    public var throughput100MB = SSHBenchmarkCaseResult()
    public var ptyResize = SSHBenchmarkCaseResult()
    public var longRunning = SSHBenchmarkCaseResult() // 10 min stability
    public var cpu = SSHBenchmarkCaseResult() // avg CPU %
    public var memory = SSHBenchmarkCaseResult() // peak MB
    public var exec1000 = SSHBenchmarkCaseResult()
    public var sftpThroughput = SSHBenchmarkCaseResult()

    public var markdownTable: String {
        func cell(_ r: SSHBenchmarkCaseResult) -> (String, String) {
            let n = r.nativeMs.map { String(format: "%.0fms", $0) } ?? "—"
            let c = r.compatMs.map { String(format: "%.0fms", $0) } ?? "—"
            return (r.nativeExtra.map { "\(n) (\($0))" } ?? n,
                    r.compatExtra.map { "\(c) (\($0))" } ?? c)
        }
        let rows: [(String, SSHBenchmarkCaseResult)] = [
            ("Connection establishment", connectionEstablishment),
            ("Interactive latency (keypress→echo)", interactiveLatency),
            ("1 MB output (`cat`)", throughput1MB),
            ("100 MB output (`cat`)", throughput100MB),
            ("PTY resize", ptyResize),
            ("Long-running (10 min idle)", longRunning),
            ("CPU (avg)", cpu),
            ("Memory (peak)", memory),
            ("1000× exec (`echo hi`)", exec1000),
            ("SFTP throughput", sftpThroughput),
        ]
        var md = "| Test | Native | Compatibility |\n|---|---|---|\n"
        for (name, r) in rows {
            let (n, c) = cell(r)
            md += "| \(name) | \(n) | \(c) |\n"
        }
        md += "\n*Host: \(host):\(port) — \(ISO8601DateFormatter().string(from: date))*"
        return md
    }
}

// MARK: - Runner

/// Measures a live SSHSession. Injected factory lets caller force Native or Compatibility.
public actor SSHBenchmarkRunner {
    public init() {}

    /// Factory: (SSHBackendType) async throws -> SSHSession
    public typealias SessionFactory = @Sendable (SSHBackendType) async throws -> any SSHSession

    public func runAll(factory: SessionFactory, host: String, port: Int, iterations: Int = 3) async -> SSHBenchmarkResult {
        var result = SSHBenchmarkResult(host: host, port: port, date: Date())
        result.connectionEstablishment = await measureConnection(factory: factory, iterations: iterations)
        result.exec1000 = await measureExec1000(factory: factory)
        result.throughput1MB = await measureThroughput(factory: factory, bytes: 1 * 1024 * 1024)
        result.throughput100MB = await measureThroughput(factory: factory, bytes: 100 * 1024 * 1024)
        result.ptyResize = await measurePTYResize(factory: factory)
        result.interactiveLatency = await measureInteractive(factory: factory)
        // CPU/Memory/LongRunning/SFTP require instruments or longer runs — placeholders
        return result
    }

    // MARK: - Individual measurements

    private func measureConnection(factory: SessionFactory, iterations: Int) async -> SSHBenchmarkCaseResult {
        var r = SSHBenchmarkCaseResult()
        r.nativeMs = await avgMs(iterations) {
            let s = try await factory(.native); defer { Task { await s.close() } }
            _ = try await s.execute("echo ok")
        }
        r.compatMs = await avgMs(iterations) {
            let s = try await factory(.compatibility); defer { Task { await s.close() } }
            _ = try await s.execute("echo ok")
        }
        return r
    }

    private func measureExec1000(factory: SessionFactory) async -> SSHBenchmarkCaseResult {
        var r = SSHBenchmarkCaseResult()
        r.nativeMs = await singleMs {
            let s = try await factory(.native); defer { Task { await s.close() } }
            for _ in 0..<1000 { _ = try await s.execute("echo hi") }
        }
        r.compatMs = await singleMs {
            let s = try await factory(.compatibility); defer { Task { await s.close() } }
            for _ in 0..<1000 { _ = try await s.execute("echo hi") }
        }
        return r
    }

    private func measureThroughput(factory: SessionFactory, bytes: Int) async -> SSHBenchmarkCaseResult {
        // Uses `cat` of generated data; server must have `head -c <bytes> /dev/zero | tr '\\0' 'a' | cat`
        let cmd = "head -c \(bytes) /dev/zero | tr '\\0' 'a' | wc -c"
        var r = SSHBenchmarkCaseResult()
        r.nativeMs = await singleMs {
            let s = try await factory(.native); defer { Task { await s.close() } }
            _ = try await s.execute(cmd)
        }
        r.compatMs = await singleMs {
            let s = try await factory(.compatibility); defer { Task { await s.close() } }
            _ = try await s.execute(cmd)
        }
        return r
    }

    private func measurePTYResize(factory: SessionFactory) async -> SSHBenchmarkCaseResult {
        var r = SSHBenchmarkCaseResult()
        r.nativeMs = await singleMs {
            let s = try await factory(.native); defer { Task { await s.close() } }
            let pty = try await s.openPTY(size: TerminalSize(cols: 80, rows: 24))
            for cols in stride(from: 80, to: 200, by: 20) { try await pty.resize(cols: cols, rows: 24) }
            await pty.close()
        }
        r.compatMs = await singleMs {
            let s = try await factory(.compatibility); defer { Task { await s.close() } }
            let pty = try await s.openPTY(size: TerminalSize(cols: 80, rows: 24))
            for cols in stride(from: 80, to: 200, by: 20) { try await pty.resize(cols: cols, rows: 24) }
            await pty.close()
        }
        return r
    }

    private func measureInteractive(factory: SessionFactory) async -> SSHBenchmarkCaseResult {
        // Keypress→echo latency via PTY write/read
        var r = SSHBenchmarkCaseResult()
        r.nativeMs = await singleMs {
            let s = try await factory(.native); defer { Task { await s.close() } }
            let pty = try await s.openPTY(size: TerminalSize(cols: 80, rows: 24))
            let start = CFAbsoluteTimeGetCurrent()
            try await pty.write(Data("echo latency_test\n".utf8))
            // consume one output chunk
            for await _ in pty.output { break }
            _ = CFAbsoluteTimeGetCurrent() - start
            await pty.close()
        }
        r.compatMs = await singleMs {
            let s = try await factory(.compatibility); defer { Task { await s.close() } }
            let pty = try await s.openPTY(size: TerminalSize(cols: 80, rows: 24))
            let start = CFAbsoluteTimeGetCurrent()
            try await pty.write(Data("echo latency_test\n".utf8))
            for await _ in pty.output { break }
            _ = CFAbsoluteTimeGetCurrent() - start
            await pty.close()
        }
        return r
    }

    // MARK: - Helpers

    private func singleMs(_ block: @Sendable () async throws -> Void) async -> Double? {
        let start = CFAbsoluteTimeGetCurrent()
        do { try await block() } catch {
            Log.ssh.error("[BENCH] singleMs failed: \(String(describing: error))")
            return nil
        }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private func avgMs(_ n: Int, _ block: @Sendable () async throws -> Void) async -> Double? {
        var total: Double = 0; var ok = 0
        for _ in 0..<n {
            if let ms = await singleMs(block) { total += ms; ok += 1 }
        }
        return ok > 0 ? total / Double(ok) : nil
    }
}
