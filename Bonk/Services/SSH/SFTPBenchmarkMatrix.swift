//
//  SFTPBenchmarkMatrix.swift
//  Bonk — Phase A SFTP experiment platform (see ⑥)
//
//  Fixed parameters, full metrics, no production behavior change:
//  - Chunk 64 KiB, pipeline 32, shards per case, via SFTPTestOverrides.
//  - Results never feed back into production routing (no SpeedRouter yet).
//  - Adaptive BDP probing, sticky downgrade, resume and pool reuse are
//    Phase 2 and intentionally absent here: fixed params first so network,
//    concurrency and server differences stay attributable.
//  - Chunk-level p50/p95 needs an engine event sink (production change) and
//    is deferred; progress-callback intervals are reported instead.
//  - Auth time is folded into connect_time (splitting it needs backend
//    hooks); cancel latency is covered by the dedicated cancelProbe kind.
//  - OpenSSH connects lazily (ControlMaster spins up on first use), so its
//    connect_ms reads near zero and the real setup cost lands in
//    first_byte_ms/total_ms. Compare first_byte + total, not connect alone.
//
//  Usage (Debug, needs live hosts + disk space):
//    let runner = SFTPMatrixRunner()
//    let report = await runner.run(endpoint: endpoint, cases: SFTPMatrixPreset.phaseA())
//    print(report.markdown())
//    try report.csv().write(to: csvURL, atomically: true, encoding: .utf8)
//

import Foundation
import Security
import os.log

// MARK: - Case Model

/// Transfer backend under test.
enum SFTPMatrixBackend: String, Codable, Sendable {
    case openSSH
    case citadel
}

/// Concurrency pattern. singleStream on Citadel means one handle, pipelined
/// (shards=1), driven through the multi-channel engine with overrides —
/// distinct from the OpenSSH CLI single process.
enum SFTPMatrixMode: String, Codable, Sendable {
    case singleStream
    case multiChannel
    case multiTCP
}

/// write/read: one file of sizeBytes. multiWrite/multiRead: fileCount files of
/// sizeBytes/fileCount (constant total payload, tests file-level concurrency,
/// e.g. NAS single-file locks vs independent files). cancelProbe: start a
/// 128MB-class upload, cancel mid-flight, measure cancel latency.
enum SFTPMatrixKind: String, Codable, Sendable {
    case write
    case read
    case multiWrite
    case multiRead
    case cancelProbe
}

struct SFTPMatrixCase: Sendable {
    var sizeBytes: UInt64
    var backend: SFTPMatrixBackend
    var mode: SFTPMatrixMode
    var shards: Int
    var kind: SFTPMatrixKind
    var fileCount: Int

    init(
        sizeBytes: UInt64,
        backend: SFTPMatrixBackend,
        mode: SFTPMatrixMode,
        shards: Int = 1,
        kind: SFTPMatrixKind = .write,
        fileCount: Int = 8
    ) {
        self.sizeBytes = sizeBytes
        self.backend = backend
        self.mode = mode
        self.shards = shards
        self.kind = kind
        self.fileCount = fileCount
    }
}

/// One endpoint under test. The harness owns sessions and channels it opens;
/// injected clients/pools stay owned by the caller (creation closures run on
/// demand, caller closes afterwards).
struct SFTPMatrixEndpoint: Sendable {
    var label: String
    var serverType: String // e.g. "openssh-linux", "macos-openssh", "nas-weak-sftp"
    var remoteBasePath: String
    var localScratchDir: URL
    var makeSession: SSHBenchmarkRunner.SessionFactory
    /// Raw Citadel SFTPClient as Any (engine casts internally). Needed for
    /// citadel singleStream/multiChannel modes.
    var makeCitadelSFTP: (@Sendable () async throws -> Any)?
    /// Fresh pool per call. Needed for citadel multiTCP mode.
    var makePool: (@Sendable (Int) async throws -> [PooledSFTPHandle])?

    init(
        label: String,
        serverType: String,
        remoteBasePath: String,
        localScratchDir: URL,
        makeSession: @escaping SSHBenchmarkRunner.SessionFactory,
        makeCitadelSFTP: (@Sendable () async throws -> Any)? = nil,
        makePool: (@Sendable (Int) async throws -> [PooledSFTPHandle])? = nil
    ) {
        self.label = label
        self.serverType = serverType
        self.remoteBasePath = remoteBasePath
        self.localScratchDir = localScratchDir
        self.makeSession = makeSession
        self.makeCitadelSFTP = makeCitadelSFTP
        self.makePool = makePool
    }
}

// MARK: - Phase A Presets

/// Fixed Phase A parameters: 64 KiB chunks, pipeline depth 32.
enum SFTPMatrixFixedParams {
    static let chunkSize = 64 * 1024
    static let pipelinePerShard = 32
}

enum SFTPMatrixPreset {
    static let sizes: [UInt64] = [
        8 * 1024 * 1024,
        32 * 1024 * 1024,
        128 * 1024 * 1024,
        512 * 1024 * 1024,
        2 * 1024 * 1024 * 1024,
    ]

    /// Phase A core: single-file write+read across backends and modes.
    /// OpenSSH supports singleStream only; other combos are skipped with reason.
    static func phaseA(sizes: [UInt64] = sizes) -> [SFTPMatrixCase] {
        var cases: [SFTPMatrixCase] = []
        for size in sizes {
            for kind in [SFTPMatrixKind.write, SFTPMatrixKind.read] {
                cases.append(SFTPMatrixCase(
                    sizeBytes: size, backend: .openSSH, mode: .singleStream, kind: kind
                ))
                cases.append(SFTPMatrixCase(
                    sizeBytes: size, backend: .citadel, mode: .singleStream, shards: 1, kind: kind
                ))
                for shards in [2, 4, 8] {
                    cases.append(SFTPMatrixCase(
                    sizeBytes: size, backend: .citadel, mode: .multiChannel, shards: shards, kind: kind
                ))
                    cases.append(SFTPMatrixCase(
                    sizeBytes: size, backend: .citadel, mode: .multiTCP, shards: shards, kind: kind
                ))
                }
            }
        }
        return cases
    }

    /// File-level concurrency subset: constant total payload across 8 files.
    static func phaseAMultiFile(sizes: [UInt64] = [32 * 1024 * 1024, 512 * 1024 * 1024]) -> [SFTPMatrixCase] {
        var cases: [SFTPMatrixCase] = []
        for size in sizes {
            for kind in [SFTPMatrixKind.multiWrite, SFTPMatrixKind.multiRead] {
                cases.append(SFTPMatrixCase(
                    sizeBytes: size, backend: .openSSH, mode: .singleStream, kind: kind
                ))
                cases.append(SFTPMatrixCase(
                    sizeBytes: size, backend: .citadel, mode: .multiChannel, shards: 4, kind: kind
                ))
                cases.append(SFTPMatrixCase(
                    sizeBytes: size, backend: .citadel, mode: .multiTCP, shards: 4, kind: kind
                ))
            }
        }
        return cases
    }

    /// Cancel-latency probes (128MB uploads cancelled ~400ms in).
    static func phaseACancelProbes() -> [SFTPMatrixCase] {
        [
            SFTPMatrixCase(sizeBytes: 128 * 1024 * 1024, backend: .openSSH, mode: .singleStream, kind: .cancelProbe),
            SFTPMatrixCase(
                sizeBytes: 128 * 1024 * 1024, backend: .citadel, mode: .multiChannel,
                shards: 4, kind: .cancelProbe
            ),
        ]
    }
}

// MARK: - Result Row

/// One measured run. Unmeasurable-without-prod-change fields stay nil with
/// the reason documented in skippedReason or the file header.
struct SFTPMatrixRow: Codable, Sendable {
    var endpoint: String
    var serverType: String
    var rttMs: Double?
    var kind: String
    var backend: String
    var mode: String
    var shards: Int
    var sizeBytes: UInt64
    var fileCount: Int
    var chunkSize: Int?
    var pipelineDepth: Int?
    var tcpConnections: Int?
    var channelsUsed: Int?
    var connectMs: Double?
    var sftpOpenMs: Double?
    var poolBuildMs: Double?
    var firstByteMs: Double?
    var totalMs: Double?
    var payloadBytes: UInt64
    var effectiveMBps: Double?
    var avgMBps: Double?
    var peakMBps: Double?
    var progressIntervalP50Ms: Double?
    var progressIntervalP95Ms: Double?
    var cancelLatencyMs: Double?
    var succeeded: Bool
    var error: String?
    var skippedReason: String?
    var observedRejection: String?
}

struct SFTPMatrixReport: Sendable {
    var endpoint: String
    var serverType: String
    var date: Date
    var rows: [SFTPMatrixRow]

    static let csvColumns = [
        "endpoint", "server_type", "rtt_ms", "kind", "backend", "mode", "shards",
        "size_bytes", "file_count", "chunk_size", "pipeline_depth",
        "tcp_connections", "channels_used", "connect_ms", "sftp_open_ms",
        "pool_build_ms", "first_byte_ms", "total_ms", "payload_bytes",
        "effective_MBps", "avg_MBps", "peak_MBps",
        "progress_interval_p50_ms", "progress_interval_p95_ms",
        "cancel_latency_ms", "succeeded", "error", "skipped_reason",
        "observed_rejection",
    ]

    func csv() -> String {
        var out = Self.csvColumns.joined(separator: ",") + "\n"
        for row in rows {
            let values: [String] = [
                row.endpoint, row.serverType, num(row.rttMs), row.kind, row.backend,
                row.mode, String(row.shards), String(row.sizeBytes), String(row.fileCount),
                num(row.chunkSize), num(row.pipelineDepth),
                num(row.tcpConnections), num(row.channelsUsed),
                num(row.connectMs), num(row.sftpOpenMs), num(row.poolBuildMs),
                num(row.firstByteMs), num(row.totalMs), String(row.payloadBytes),
                num(row.effectiveMBps), num(row.avgMBps), num(row.peakMBps),
                num(row.progressIntervalP50Ms), num(row.progressIntervalP95Ms),
                num(row.cancelLatencyMs), row.succeeded ? "1" : "0",
                str(row.error), str(row.skippedReason), str(row.observedRejection),
            ]
            out += values.joined(separator: ",") + "\n"
        }
        return out
    }

    func json() throws -> String {
        let data = try JSONEncoder().encode(rows)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Compact pivot: effective MBps by size/backend/mode (write only).
    func markdown() -> String {
        var markdown = "| size | backend/mode/shards | kind | effective MBps | total | first byte | note |\n"
        markdown += "|---|---|---|---|---|---|---|\n"
        for row in rows {
            let rate = row.effectiveMBps.map { String(format: "%.1f", $0) } ?? "—"
            let total = row.totalMs.map { String(format: "%.0fms", $0) } ?? "—"
            let first = row.firstByteMs.map { String(format: "%.0fms", $0) } ?? "—"
            let note = row.skippedReason ?? row.error ?? ""
            markdown += "| \(row.sizeBytes) | \(row.backend)/\(row.mode)/\(row.shards)"
            markdown += " | \(row.kind) | \(rate) | \(total) | \(first) | \(note) |\n"
        }
        markdown += "\n*Endpoint: \(endpoint) (\(serverType)) — \(ISO8601DateFormatter().string(from: date))*\n"
        return markdown
    }
}

private func num(_ value: Double?) -> String {
    value.map { String(format: "%.3f", $0) } ?? ""
}

private func num(_ value: Int?) -> String {
    value.map(String.init) ?? ""
}

private func str(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "" }
    return "\"" + value.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
}

// MARK: - Progress Recorder (off-MainActor, lock-guarded)

final class SFTPBenchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var start = Date()
    private var firstByte: Date?
    private var samples: [(Date, Double)] = []

    func record(_ progress: Double) {
        let now = Date()
        lock.lock()
        if firstByte == nil, progress > 0 { firstByte = now }
        samples.append((now, progress))
        lock.unlock()
    }

    struct Summary: Sendable {
        var firstByteMs: Double?
        var totalMs: Double
        var avgMBps: Double?
        var peakMBps: Double?
        var intervalP50Ms: Double?
        var intervalP95Ms: Double?
    }

    func summary(totalBytes: UInt64) -> Summary {
        lock.lock()
        defer { lock.unlock() }
        let end = samples.last?.0 ?? Date()
        let totalMs = end.timeIntervalSince(start) * 1000
        let firstByteMs = firstByte.map { $0.timeIntervalSince(start) * 1000 }
        var avg: Double?
        var peak: Double?
        var p50: Double?
        var p95: Double?
        if samples.count >= 2, let first = samples.first, let last = samples.last,
           last.0 > first.0
        {
            let span = last.0.timeIntervalSince(first.0)
            if span > 0 { avg = Double(totalBytes) / span / (1024 * 1024) }
            var intervals: [Double] = []
            for sampleIndex in 1..<samples.count {
                let deltaT = samples[sampleIndex].0.timeIntervalSince(samples[sampleIndex - 1].0)
                intervals.append(deltaT * 1000)
            }
            // Peak over 100ms windows; sub-200ms runs report the effective rate
            // instead (per-callback instant rates are noise on fast links).
            let window: TimeInterval = 0.1
            var windowStart = first.0
            var windowProgress = first.1
            var best: Double = 0
            for sample in samples.dropFirst() {
                if sample.0.timeIntervalSince(windowStart) >= window {
                    let windowSpan = sample.0.timeIntervalSince(windowStart)
                    let windowRate = Double(totalBytes) * max(0, sample.1 - windowProgress) / windowSpan / (1024 * 1024)
                    best = max(best, windowRate)
                    windowStart = sample.0
                    windowProgress = sample.1
                }
            }
            let effective = totalMs > 0 ? Double(totalBytes) / (totalMs / 1000) / (1024 * 1024) : 0
            peak = totalMs < 200 ? effective : max(best, effective)
            p50 = percentile(intervals, 0.5)
            p95 = percentile(intervals, 0.95)
        }
        return Summary(
            firstByteMs: firstByteMs, totalMs: totalMs, avgMBps: avg,
            peakMBps: peak, intervalP50Ms: p50, intervalP95Ms: p95
        )
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * quantile))
        return sorted[idx]
    }
}

// MARK: - Runner

/// Drives the matrix. Fresh session per case so connect_time is meaningful.
/// Caller must ensure disk space (payload + download copies) and remote
/// write permission; remote fixtures are cleaned up best-effort.
actor SFTPMatrixRunner {
    init() {}

    func run(
        endpoint: SFTPMatrixEndpoint,
        cases: [SFTPMatrixCase],
        timeoutSeconds: Int = 1200
    ) async -> SFTPMatrixReport {
        var rows: [SFTPMatrixRow] = []
        let rtt = await measureRTT(endpoint: endpoint)
        for (index, matrixCase) in cases.enumerated() {
            let row: SFTPMatrixRow
            do {
                row = try await withThrowingTimeout(of: .seconds(timeoutSeconds)) {
                    try await self.runCase(endpoint: endpoint, matrixCase: matrixCase, index: index, rttMs: rtt)
                }
            } catch {
                row = self.failedRow(
                endpoint: endpoint, matrixCase: matrixCase, rttMs: rtt,
                error: String(describing: error)
            )
            }
            rows.append(row)
        }
        return SFTPMatrixReport(endpoint: endpoint.label, serverType: endpoint.serverType, date: Date(), rows: rows)
    }

    // MARK: - Per-case dispatch

    private func runCase(
        endpoint: SFTPMatrixEndpoint,
        matrixCase: SFTPMatrixCase,
        index: Int,
        rttMs: Double?
    ) async throws -> SFTPMatrixRow {
        // Mode/backend validity without touching production routing.
        if matrixCase.backend == .openSSH, matrixCase.mode != .singleStream {
            return skippedRow(
                endpoint: endpoint, matrixCase: matrixCase, rttMs: rttMs,
                reason: "openSSH supports singleStream only"
            )
        }
        if matrixCase.backend == .citadel, matrixCase.mode != .singleStream,
            endpoint.makeCitadelSFTP == nil, matrixCase.mode == .multiChannel {
            return skippedRow(
                endpoint: endpoint, matrixCase: matrixCase, rttMs: rttMs,
                reason: "citadel multiChannel needs makeCitadelSFTP"
            )
        }
        if matrixCase.mode == .multiTCP, endpoint.makePool == nil {
            return skippedRow(
                endpoint: endpoint, matrixCase: matrixCase, rttMs: rttMs,
                reason: "multiTCP needs makePool"
            )
        }
        if matrixCase.kind == .cancelProbe {
            return try await runCancelProbe(endpoint: endpoint, matrixCase: matrixCase, index: index, rttMs: rttMs)
        }

        let remoteDir = "\(endpoint.remoteBasePath)/bench_\(Int(Date().timeIntervalSince1970))_\(index)"
        try checkLocalSpace(scratch: endpoint.localScratchDir, bytes: matrixCase.sizeBytes * 3)
        let startTime = Date()
        let backendType: SSHBackendType = matrixCase.backend == .openSSH ? .compatibility : .native
        let session = try await endpoint.makeSession(backendType)
        let connectMs = Date().timeIntervalSince(startTime) * 1000
        defer { Task { await session.close() } }

        do {
            _ = try await session.execute("mkdir -p \(shellQuote(remoteDir))")
        } catch {
            return failedRow(
                endpoint: endpoint, matrixCase: matrixCase, rttMs: rttMs,
                error: "mkdir failed: \(error)", connectMs: connectMs
            )
        }
        defer { Task { _ = try? await session.execute("rm -rf \(shellQuote(remoteDir))") } }

        switch matrixCase.kind {
        case .write:
            let ctx = RunContext(
                endpoint: endpoint, session: session, remoteDir: remoteDir,
                index: index, rttMs: rttMs, connectMs: connectMs
            )
            return try await runWrite(ctx: ctx, matrixCase: matrixCase)
        case .read:
            let ctx = RunContext(
                endpoint: endpoint, session: session, remoteDir: remoteDir,
                index: index, rttMs: rttMs, connectMs: connectMs
            )
            return try await runRead(ctx: ctx, matrixCase: matrixCase)
        case .multiWrite, .multiRead:
            let ctx = RunContext(
                endpoint: endpoint, session: session, remoteDir: remoteDir,
                index: index, rttMs: rttMs, connectMs: connectMs
            )
            return try await runMulti(ctx: ctx, matrixCase: matrixCase)
        case .cancelProbe:
            throw SFTPServiceError.operationFailed("unreachable")
        }
    }

    // MARK: - Write / Read

    /// Shared per-case context; keeps runner methods within the parameter budget.
    struct RunContext: Sendable {
        var endpoint: SFTPMatrixEndpoint
        var session: any SSHSession
        var remoteDir: String
        var index: Int
        var rttMs: Double?
        var connectMs: Double
    }

    private func runWrite(ctx: RunContext, matrixCase: SFTPMatrixCase) async throws -> SFTPMatrixRow {
        let local = try self.payloadFile(size: matrixCase.sizeBytes, scratch: ctx.endpoint.localScratchDir)
        let remote = "\(ctx.remoteDir)/payload.bin"
        let recorder = SFTPBenchRecorder()
        var row = baseRow(endpoint: ctx.endpoint, matrixCase: matrixCase, rttMs: ctx.rttMs, connectMs: ctx.connectMs)
        do {
            let (openMs, poolMs) = try await singleUpload(
                recorder: recorder, endpoint: ctx.endpoint, session: ctx.session,
                matrixCase: matrixCase, local: local, remote: remote
            )
            row.sftpOpenMs = openMs
            row.poolBuildMs = poolMs
            fillFromRecorder(recorder: recorder, row: &row, payload: matrixCase.sizeBytes)
            row.succeeded = true
        } catch {
            row.succeeded = false
            row.error = String(describing: error)
            row.observedRejection = rejectionHint(error)
        }
        return row
    }

    private func runRead(ctx: RunContext, matrixCase: SFTPMatrixCase) async throws -> SFTPMatrixRow {
        // Untimed fixture setup via the simplest path.
        let local = try self.payloadFile(size: matrixCase.sizeBytes, scratch: ctx.endpoint.localScratchDir)
        let remote = "\(ctx.remoteDir)/payload.bin"
        let setup = try await ctx.session.openSFTP()
        try await setup.upload(local, to: remote, operationID: UUID(), onProgress: { _ in })
        await setup.close()
        let dest = ctx.endpoint.localScratchDir.appendingPathComponent("bench_dl_\(ctx.index).bin")
        try? FileManager.default.removeItem(at: dest)
        let recorder = SFTPBenchRecorder()
        var row = baseRow(endpoint: ctx.endpoint, matrixCase: matrixCase, rttMs: ctx.rttMs, connectMs: ctx.connectMs)
        do {
            let (openMs, poolMs) = try await singleDownload(
                recorder: recorder, endpoint: ctx.endpoint, session: ctx.session,
                matrixCase: matrixCase, local: dest, remote: remote
            )
            row.sftpOpenMs = openMs
            row.poolBuildMs = poolMs
            fillFromRecorder(recorder: recorder, row: &row, payload: matrixCase.sizeBytes)
            row.succeeded = true
        } catch {
            row.succeeded = false
            row.error = String(describing: error)
            row.observedRejection = rejectionHint(error)
        }
        try? FileManager.default.removeItem(at: dest)
        return row
    }

    // MARK: - Multi-file

    private func runMulti(ctx: RunContext, matrixCase: SFTPMatrixCase) async throws -> SFTPMatrixRow {
        let count = max(1, matrixCase.fileCount)
        let perFile = matrixCase.sizeBytes / UInt64(count)
        let isWrite = matrixCase.kind == .multiWrite
        var row = baseRow(endpoint: ctx.endpoint, matrixCase: matrixCase, rttMs: ctx.rttMs, connectMs: ctx.connectMs)
        // Read setup mirrors write: fixtures must exist remotely first.
        if !isWrite {
            let setup = try await ctx.session.openSFTP()
            for fileIndex in 0..<count {
                let local = try self.payloadFile(size: perFile, scratch: ctx.endpoint.localScratchDir)
                try await setup.upload(
                    local, to: "\(ctx.remoteDir)/f\(fileIndex).bin",
                    operationID: UUID(), onProgress: { _ in }
                )
            }
            await setup.close()
        }
        let recorder = SFTPBenchRecorder()
        let total = perFile * UInt64(count)
        do {
            if isWrite {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for fileIndex in 0..<count {
                        group.addTask {
                            let local = try self.payloadFile(size: perFile, scratch: ctx.endpoint.localScratchDir)
                            _ = try await self.singleUpload(
                                recorder: recorder, endpoint: ctx.endpoint, session: ctx.session,
                                matrixCase: matrixCase, local: local, remote: "\(ctx.remoteDir)/f\(fileIndex).bin"
                            )
                        }
                    }
                    try await group.waitForAll()
                }
            } else {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for fileIndex in 0..<count {
                        group.addTask {
                            let dest = ctx.endpoint.localScratchDir.appendingPathComponent(
                                "bench_mdl_\(ctx.index)_\(fileIndex).bin"
                            )
                            try? FileManager.default.removeItem(at: dest)
                            _ = try await self.singleDownload(
                                recorder: recorder, endpoint: ctx.endpoint, session: ctx.session,
                                matrixCase: matrixCase, local: dest, remote: "\(ctx.remoteDir)/f\(fileIndex).bin"
                            )
                            try? FileManager.default.removeItem(at: dest)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            fillFromRecorder(recorder: recorder, row: &row, payload: total)
            row.succeeded = true
        } catch {
            row.succeeded = false
            row.error = String(describing: error)
            row.observedRejection = rejectionHint(error)
        }
        return row
    }

    // MARK: - Cancel probe (public seam only)

    private func runCancelProbe(
        endpoint: SFTPMatrixEndpoint,
        matrixCase: SFTPMatrixCase,
        index: Int,
        rttMs: Double?
    ) async throws -> SFTPMatrixRow {
        var row = baseRow(endpoint: endpoint, matrixCase: matrixCase, rttMs: rttMs, connectMs: nil)
        let backendType: SSHBackendType = matrixCase.backend == .openSSH ? .compatibility : .native
        let startTime = Date()
        let session = try await endpoint.makeSession(backendType)
        row.connectMs = Date().timeIntervalSince(startTime) * 1000
        defer { Task { await session.close() } }
        let local = try self.payloadFile(size: matrixCase.sizeBytes, scratch: endpoint.localScratchDir)
        let remoteDir = "\(endpoint.remoteBasePath)/bench_cancel_\(index)"
        _ = try? await session.execute("mkdir -p \(shellQuote(remoteDir))")
        defer { Task { _ = try? await session.execute("rm -rf \(shellQuote(remoteDir))") } }
        let service = await SFTPService()
        do {
            try await service.connect(using: session)
        } catch {
            row.succeeded = false
            row.error = "sftp connect failed: \(error)"
            return row
        }
        defer { Task { await service.disconnect() } }
        let remote = "\(remoteDir)/cancel.bin"
        // Race: upload stream vs canceller. No task group (its inout group
        // cannot be referenced from child closures).
        let uploadTask = Task<Void, Error> {
            for try await _ in await service.upload(local, to: remote) {}
        }
        try await Task.sleep(for: .milliseconds(400))
        var found = false
        for _ in 0..<100 {
            let id: UUID? = await MainActor.run {
                service.transfers.first(where: { !$0.isComplete && !$0.isCancelled })?.id
            }
            if let id {
                found = true
                let tCancel = Date()
                await MainActor.run { service.cancelTransfer(id) }
                do {
                    try await uploadTask.value
                    row.succeeded = false
                    row.error = "completed before cancel landed"
                } catch {
                    row.cancelLatencyMs = Date().timeIntervalSince(tCancel) * 1000
                    row.succeeded = true
                }
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !found {
            row.succeeded = false
            row.error = "no active transfer to cancel"
            uploadTask.cancel()
        }
        row.payloadBytes = matrixCase.sizeBytes
        return row
    }

    // MARK: - Transfer dispatch (fixed params, no auto-routing)

    /// Engine/channel dispatch shared by single and multi-file cases.
    /// nonisolated so TaskGroup bodies can call it; all collaborators are Sendable.
    private nonisolated func singleUpload(
        recorder: SFTPBenchRecorder,
        endpoint: SFTPMatrixEndpoint,
        session: any SSHSession,
        matrixCase: SFTPMatrixCase,
        local: URL,
        remote: String
    ) async throws -> (openMs: Double?, poolMs: Double?) {
        let overrides = SFTPTestOverrides(
            shards: matrixCase.shards,
            pipelinePerShard: SFTPMatrixFixedParams.pipelinePerShard,
            chunkSize: SFTPMatrixFixedParams.chunkSize
        )
        var openMs: Double?
        var poolMs: Double?
        let total = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? UInt64) ?? 0
        switch (matrixCase.backend, matrixCase.mode) {
        case (.openSSH, .singleStream):
            let tOpen = Date()
            let channel = try await session.openSFTP()
            openMs = Date().timeIntervalSince(tOpen) * 1000
            try await channel.upload(local, to: remote, operationID: UUID(), onProgress: { recorder.record($0) })
            await channel.close()
        case (.citadel, .singleStream), (.citadel, .multiChannel):
            guard let makeRaw = endpoint.makeCitadelSFTP else {
                throw SFTPServiceError.operationFailed("citadel mode needs makeCitadelSFTP")
            }
            let tOpen = Date()
            let raw = try await makeRaw()
            openMs = Date().timeIntervalSince(tOpen) * 1000
            try await SFTPParallelTransferEngine.parallelUploadMultiChannel(
                sftp: raw, remotePath: remote, localURL: local, totalBytes: total,
                isCancelled: { false },
                onProgress: { recorder.record($0) },
                overrides: overrides
            )
        case (.citadel, .multiTCP):
            guard let makePool = endpoint.makePool else {
                throw SFTPServiceError.operationFailed("multiTCP needs makePool")
            }
            let tOpen = Date()
            let pool = try await makePool(matrixCase.shards)
            poolMs = Date().timeIntervalSince(tOpen) * 1000
            defer { let handles = pool; Task { for handle in handles { await handle.close() } } }
            try await SFTPParallelTransferEngine.parallelUploadMultiTCP(
                handles: pool, remotePath: remote, localURL: local, totalBytes: total,
                isCancelled: { false },
                onProgress: { recorder.record($0) },
                overrides: overrides
            )
        case (.openSSH, _):
            throw SFTPServiceError.operationFailed("openSSH supports singleStream only")
        }
        return (openMs, poolMs)
    }

    private nonisolated func singleDownload(
        recorder: SFTPBenchRecorder,
        endpoint: SFTPMatrixEndpoint,
        session: any SSHSession,
        matrixCase: SFTPMatrixCase,
        local: URL,
        remote: String
    ) async throws -> (openMs: Double?, poolMs: Double?) {
        let overrides = SFTPTestOverrides(
            shards: matrixCase.shards,
            pipelinePerShard: SFTPMatrixFixedParams.pipelinePerShard,
            chunkSize: SFTPMatrixFixedParams.chunkSize
        )
        var openMs: Double?
        var poolMs: Double?
        // Size via a throwaway stat: list parent and match. Short-lived sftp
        // processes occasionally fail back-to-back; retry briefly.
        let parent = (remote as NSString).deletingLastPathComponent
        let name = (remote as NSString).lastPathComponent
        let probe = try await session.openSFTP()
        var total: UInt64?
        var lastStatError: Error?
        for _ in 0..<3 {
            do {
                let entries = try await probe.listDirectory(at: parent.isEmpty ? "." : parent)
                if let size = entries.first(where: { $0.name == name })?.size {
                    total = size
                    break
                }
            } catch {
                lastStatError = error
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        await probe.close()
        guard let total else {
            throw lastStatError ?? SFTPServiceError.operationFailed("cannot stat remote fixture: \(remote)")
        }
        switch (matrixCase.backend, matrixCase.mode) {
        case (.openSSH, .singleStream):
            let tOpen = Date()
            let channel = try await session.openSFTP()
            openMs = Date().timeIntervalSince(tOpen) * 1000
            try await channel.download(remote, to: local, operationID: UUID(), onProgress: { recorder.record($0) })
            await channel.close()
        case (.citadel, .singleStream), (.citadel, .multiChannel):
            guard let makeRaw = endpoint.makeCitadelSFTP else {
                throw SFTPServiceError.operationFailed("citadel mode needs makeCitadelSFTP")
            }
            let tOpen = Date()
            let raw = try await makeRaw()
            openMs = Date().timeIntervalSince(tOpen) * 1000
            try await SFTPParallelTransferEngine.parallelDownloadMultiChannel(
                sftp: raw, remotePath: remote, localURL: local, totalBytes: total,
                isCancelled: { false },
                onProgress: { recorder.record($0) },
                overrides: overrides
            )
        case (.citadel, .multiTCP):
            guard let makePool = endpoint.makePool else {
                throw SFTPServiceError.operationFailed("multiTCP needs makePool")
            }
            let tOpen = Date()
            let pool = try await makePool(matrixCase.shards)
            poolMs = Date().timeIntervalSince(tOpen) * 1000
            defer { let handles = pool; Task { for handle in handles { await handle.close() } } }
            try await SFTPParallelTransferEngine.parallelDownloadMultiTCP(
                handles: pool, remotePath: remote, localURL: local, totalBytes: total,
                isCancelled: { false },
                onProgress: { recorder.record($0) },
                overrides: overrides
            )
        case (.openSSH, _):
            throw SFTPServiceError.operationFailed("openSSH supports singleStream only")
        }
        return (openMs, poolMs)
    }

    // MARK: - Row helpers

    private func baseRow(
        endpoint: SFTPMatrixEndpoint,
        matrixCase: SFTPMatrixCase,
        rttMs: Double?,
        connectMs: Double?
    ) -> SFTPMatrixRow {
        SFTPMatrixRow(
            endpoint: endpoint.label, serverType: endpoint.serverType, rttMs: rttMs,
            kind: matrixCase.kind.rawValue, backend: matrixCase.backend.rawValue,
            mode: matrixCase.mode.rawValue, shards: matrixCase.shards,
            sizeBytes: matrixCase.sizeBytes,
            fileCount: matrixCase.kind == .multiWrite || matrixCase.kind == .multiRead
                ? matrixCase.fileCount : 1,
            chunkSize: matrixCase.backend == .citadel ? SFTPMatrixFixedParams.chunkSize : nil,
            pipelineDepth: matrixCase.backend == .citadel ? SFTPMatrixFixedParams.pipelinePerShard : nil,
            tcpConnections: matrixCase.mode == .multiTCP ? matrixCase.shards : 1,
            channelsUsed: matrixCase.mode == .singleStream ? 1 : matrixCase.shards,
            connectMs: connectMs, sftpOpenMs: nil, poolBuildMs: nil,
            firstByteMs: nil, totalMs: nil, payloadBytes: matrixCase.sizeBytes,
            effectiveMBps: nil, avgMBps: nil, peakMBps: nil,
            progressIntervalP50Ms: nil, progressIntervalP95Ms: nil,
            cancelLatencyMs: nil, succeeded: false, error: nil,
            skippedReason: nil, observedRejection: nil
        )
    }

    private func fillFromRecorder(recorder: SFTPBenchRecorder, row: inout SFTPMatrixRow, payload: UInt64) {
        let summary = recorder.summary(totalBytes: payload)
        row.firstByteMs = summary.firstByteMs
        row.totalMs = summary.totalMs
        row.payloadBytes = payload
        if summary.totalMs > 0 {
            row.effectiveMBps = Double(payload) / (summary.totalMs / 1000) / (1024 * 1024)
        }
        row.avgMBps = summary.avgMBps
        row.peakMBps = summary.peakMBps
        row.progressIntervalP50Ms = summary.intervalP50Ms
        row.progressIntervalP95Ms = summary.intervalP95Ms
    }

    private func failedRow(
        endpoint: SFTPMatrixEndpoint,
        matrixCase: SFTPMatrixCase,
        rttMs: Double?,
        error: String,
        connectMs: Double? = nil
    ) -> SFTPMatrixRow {
        var row = baseRow(endpoint: endpoint, matrixCase: matrixCase, rttMs: rttMs, connectMs: connectMs)
        row.succeeded = false
        row.error = error
        row.observedRejection = nil
        return row
    }

    private func skippedRow(
        endpoint: SFTPMatrixEndpoint,
        matrixCase: SFTPMatrixCase,
        rttMs: Double?,
        reason: String
    ) -> SFTPMatrixRow {
        var row = baseRow(endpoint: endpoint, matrixCase: matrixCase, rttMs: rttMs, connectMs: nil)
        row.succeeded = false
        row.skippedReason = reason
        return row
    }

    private func rejectionHint(_ error: Error) -> String? {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("MaxSessions")
            || text.localizedCaseInsensitiveContains("session limit")
        {
            return text
        }
        return nil
    }

    // MARK: - Shared setup helpers

    private func measureRTT(endpoint: SFTPMatrixEndpoint) async -> Double? {
        do {
            let session = try await endpoint.makeSession(.compatibility)
            defer { Task { await session.close() } }
            var samples: [Double] = []
            for _ in 0..<3 {
                let startTime = Date()
                _ = try await session.execute("echo ok")
                samples.append(Date().timeIntervalSince(startTime) * 1000)
            }
            return samples.reduce(0, +) / Double(samples.count)
        } catch {
            Log.ssh.warning("[BENCH] RTT probe failed: \(String(describing: error))")
            return nil
        }
    }

    private func checkLocalSpace(scratch: URL, bytes: UInt64) throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let values = try scratch.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, UInt64(free) < bytes {
            throw SFTPServiceError.operationFailed(
                "insufficient local scratch space: need \(bytes) have \(free)"
            )
        }
    }

    /// Deterministic payload: 1 MiB random block repeated. Cached by size.
    private nonisolated func payloadFile(size: UInt64, scratch: URL) throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("payload_\(size).bin")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? UInt64) == size
        {
            return url
        }
        var block = Data(count: 1024 * 1024)
        _ = block.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var remaining = size
        while remaining > 0 {
            let chunkBytes = min(UInt64(block.count), remaining)
            try handle.write(contentsOf: block.prefix(Int(chunkBytes)))
            remaining -= chunkBytes
        }
        return url
    }

    private nonisolated func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
