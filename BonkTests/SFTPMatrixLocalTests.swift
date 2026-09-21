//
//  SFTPMatrixLocalTests.swift
//  BonkTests — local Phase A smoke for SFTPBenchmarkMatrix.
//
//  Requires local bench containers (see docs/sftp-bench-local.md or ask):
//    bench-linux (127.0.0.1:2222, openssh-linux) + bench-constrained (:2223)
//  Skips gracefully when they are absent so CI stays green.
//  Writes CSV to /tmp/bench_matrix_smoke.csv and prints the markdown pivot.
//

import XCTest
@testable import Bonk
import Citadel
import Foundation

/// Accept-all host key store, test-only.
private actor AcceptAllHostKeyStore: SSHHostKeyStore {
    private var saved: [String: SSHHostFingerprint] = [:]
    func knownFingerprint(for host: String, port: UInt16) async -> SSHHostFingerprint? {
        saved["\(host):\(port)"]
    }
    func saveFingerprint(_ fingerprint: SSHHostFingerprint, for host: String, port: UInt16) async {
        saved["\(host):\(port)"] = fingerprint
    }
}

/// File-scoped CSV append: captures nothing, safe for @Sendable callbacks.
func appendMatrixCSVRow(_ row: SFTPMatrixRow, to csvURL: URL) {
    let line = SFTPMatrixReport.csvRow(row) + "\n"
    if FileManager.default.fileExists(atPath: csvURL.path),
       let handle = try? FileHandle(forWritingTo: csvURL)
    {
        try? handle.seekToEnd()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        let header = SFTPMatrixReport.csvHeader + "\n" + line
        try? header.write(to: csvURL, atomically: true, encoding: .utf8)
    }
}

final class SFTPMatrixLocalTests: XCTestCase {
    private static let password = "benchpass"
    private static let store = AcceptAllHostKeyStore()

    private func config(port: UInt16) -> SSHConnectionConfig {
        SSHConnectionConfig(
            host: "127.0.0.1", port: port,
            username: "root", authMethod: .password(Self.password)
        )
    }

    fileprivate static func nativeClient(config: SSHConnectionConfig) async throws -> SSHClient {
        try await SSHClient.connect(
            host: config.host, port: Int(config.port),
            authenticationMethod: .passwordBased(username: config.username, password: password),
            hostKeyValidator: .custom(HostKeyValidator { _ in }),
            reconnect: .never,
            algorithms: .all
        )
    }

    private func endpoint(port: UInt16, label: String, serverType: String) -> SFTPMatrixEndpoint {
        let cfg = config(port: port)
        let store = Self.store
        let password = Self.password
        let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_\(port)", isDirectory: true)
        return SFTPMatrixEndpoint(
            label: label,
            serverType: serverType,
            remoteBasePath: "/tmp/bench",
            localScratchDir: scratch,
            makeSession: { backend in
                let endpoint = SSHEndpoint(host: "127.0.0.1", port: port)
                switch backend {
                case .compatibility:
                    let backend = try OpenSSHBackend(config: cfg)
                    return CompatibilitySSHSession(backend: backend, endpoint: endpoint) as any SSHSession
                case .native:
                    let client = try await SSHClient.connect(
                        host: cfg.host, port: Int(cfg.port),
                        authenticationMethod: .passwordBased(username: cfg.username, password: password),
                        hostKeyValidator: .custom(HostKeyValidator { _ in }),
                        reconnect: .never,
                        algorithms: .all
                    )
                    let session = NativeSSHSession(
                        client: client, endpoint: endpoint, config: cfg, hostKeyStore: store
                    )
                    return session as any SSHSession
                }
            },
            makeCitadelSFTP: {
                try await Self.nativeClient(config: cfg).openSFTP() as Any
            },
            makePool: { count in try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: count) }
        )
    }

    private func tcpOpen(port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Full Phase A driver. Configure via /tmp/bench_config.json (one xcodebuild
    /// call = one batch): {port,label,serverType,sizesMb:[8,32],core,multi,
    /// cancel,pool}. Appends rows to /tmp/bench_matrix_full.csv.
    /// NOTE: `pool` currently only affects the multi branch, and pool cells
    /// are recorded as failures until the pool-in-runner P1 (testDiagMkdir)
    /// is triaged — keep pool:false for campaign batches.
    private struct BatchConfig: Decodable {
        var port: UInt16 = 2222
        var label: String = "loopback"
        var serverType: String = "openssh-linux-alpine"
        var sizesMb: [UInt64] = [8, 32]
        var core: Bool = true
        var multi: Bool = false
        var cancel: Bool = false
        var pool: Bool = true

        enum CodingKeys: String, CodingKey {
            case port, label, serverType, sizesMb, core, multi, cancel, pool
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 2222
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? "loopback"
            serverType = try container.decodeIfPresent(String.self, forKey: .serverType) ?? "openssh-linux-alpine"
            sizesMb = try container.decodeIfPresent([UInt64].self, forKey: .sizesMb) ?? [8, 32]
            core = try container.decodeIfPresent(Bool.self, forKey: .core) ?? true
            multi = try container.decodeIfPresent(Bool.self, forKey: .multi) ?? false
            cancel = try container.decodeIfPresent(Bool.self, forKey: .cancel) ?? false
            pool = try container.decodeIfPresent(Bool.self, forKey: .pool) ?? true
        }
    }

    func testFullMatrixEnvDriven() async throws {
        var batch = BatchConfig()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/bench_config.json")),
           let decoded = try? JSONDecoder().decode(BatchConfig.self, from: data)
        {
            batch = decoded
        }
        guard tcpOpen(port: batch.port) else {
            throw XCTSkip("bench server 127.0.0.1:\(batch.port) absent")
        }
        var cases = buildBatchCases(batch)
        if batch.cancel {
            cases.append(contentsOf: SFTPMatrixPreset.phaseACancelProbes())
        }
        guard !cases.isEmpty else {
            throw XCTSkip("empty batch: enable at least one of core/multi/cancel")
        }
        let runner = SFTPMatrixRunner()
        let endpoint = endpoint(port: batch.port, label: batch.label, serverType: batch.serverType)
        let csvURL = URL(fileURLWithPath: "/tmp/bench_matrix_full.csv")
        // Stream rows incrementally so killed runs keep partial data.
        let report = await runner.run(
            endpoint: endpoint, cases: cases, timeoutSeconds: 180
        ) { [csvURL] row in
            appendMatrixCSVRow(row, to: csvURL)
        }
        print("MATRIX-BATCH label=\(batch.label) cases=\(cases.count) rows=\(report.rows.count)")
        print(report.markdown())
        XCTAssertEqual(report.rows.count, cases.count, "every case must produce a row")
        let skipped = report.rows.filter { $0.skippedReason != nil }
        XCTAssertTrue(skipped.isEmpty, "unexpected skips")
    }

    private func buildBatchCases(_ batch: BatchConfig) -> [SFTPMatrixCase] {
        var cases: [SFTPMatrixCase] = []
        if batch.core {
            for size in batch.sizesMb.map({ $0 * 1024 * 1024 }) {
                for kind in [SFTPMatrixKind.write, SFTPMatrixKind.read] as [SFTPMatrixKind] {
                    cases.append(singleCell(size: size, kind: kind, backend: .openSSH))
                    cases.append(singleCell(size: size, kind: kind, backend: .citadel))
                    for shards in [2, 4, 8] {
                        cases.append(channelCell(size: size, kind: kind, shards: shards))
                    }
                }
            }
        }
        if batch.multi {
            for size in batch.sizesMb.map({ $0 * 1024 * 1024 }) {
                for kind in [SFTPMatrixKind.multiWrite, SFTPMatrixKind.multiRead] as [SFTPMatrixKind] {
                    cases.append(multiCell(size: size, kind: kind, backend: .openSSH, shards: 1))
                    cases.append(multiCell(size: size, kind: kind, backend: .citadel, shards: 4))
                    if batch.pool {
                        cases.append(poolMultiCell(size: size, kind: kind))
                    }
                }
            }
        }
        return cases
    }

    private func singleCell(size: UInt64, kind: SFTPMatrixKind, backend: SFTPMatrixBackend) -> SFTPMatrixCase {
        SFTPMatrixCase(sizeBytes: size, backend: backend, mode: .singleStream, shards: 1, kind: kind)
    }

    private func channelCell(size: UInt64, kind: SFTPMatrixKind, shards: Int) -> SFTPMatrixCase {
        SFTPMatrixCase(sizeBytes: size, backend: .citadel, mode: .multiChannel, shards: shards, kind: kind)
    }

    // NOTE: no poolCell helper — pool cells stay out of the matrix until the
    // pool-in-runner P1 (testDiagMkdir) is triaged. Re-add with the fix.

    private func multiCell(
        size: UInt64, kind: SFTPMatrixKind, backend: SFTPMatrixBackend, shards: Int
    ) -> SFTPMatrixCase {
        let mode: SFTPMatrixMode = backend == .openSSH ? .singleStream : .multiChannel
        return SFTPMatrixCase(sizeBytes: size, backend: backend, mode: mode, shards: shards, kind: kind)
    }

    private func poolMultiCell(size: UInt64, kind: SFTPMatrixKind) -> SFTPMatrixCase {
        SFTPMatrixCase(sizeBytes: size, backend: .citadel, mode: .multiTCP, shards: 4, kind: kind)
    }

    /// P1 repro: single pool case through the runner dies in first openFile
    /// ("pool-transfer: I/O on closed channel") while the identical pool +
    /// transfer succeeds standalone. See ⑦ notes before enabling pool cells.
    /// Read-overlap microbench: proves concurrent reads on one Citadel handle
    /// overlap (CONC4 < SEQ4) instead of serializing. Guard for the download
    /// path: if a change makes CONC4 regress toward SEQ4, pipelining broke.
    /// Writes results to /tmp/diagpool.txt; informational only (no asserts).
    func testDiagReadOverlap() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        var log = ""
        do {
            let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
            let local = scratch.appendingPathComponent("payload_33554432.bin")
            // Seed remote fixture via OpenSSH channel (known-good path).
            let setupBackend = try OpenSSHBackend(config: cfg)
            let setupChannel = try await CompatibilitySSHSession(
                backend: setupBackend, endpoint: SSHEndpoint(host: "127.0.0.1", port: 2222)
            ).openSFTP()
            try await setupChannel.upload(local, to: "/tmp/seqtest.bin", operationID: UUID(), onProgress: { _ in })
            await setupChannel.close()
            let client = try await Self.nativeClient(config: cfg)
            let sftp = try await client.openSFTP()
            let file = try await sftp.openFile(filePath: "/tmp/seqtest.bin", flags: [.read])
            let remoteFile = SendableSFTPFile(file)
            // Sequential baseline: 4 x 64K reads back-to-back.
            var start = Date()
            for off in [0, 65536, 131072, 196608] as [UInt64] {
                _ = try await SFTPTransferEngine.readChunk(remoteFile, offset: off, length: 65536)
            }
            log += "SEQ4-MS=\(Date().timeIntervalSince(start) * 1000)\n"
            // Concurrent: 4 x 64K reads racing on one handle.
            start = Date()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for off in [0, 65536, 131072, 196608] as [UInt64] {
                    group.addTask {
                        _ = try await SFTPTransferEngine.readChunk(remoteFile, offset: off, length: 65536)
                    }
                }
                try await group.waitForAll()
            }
            log += "CONC4-MS=\(Date().timeIntervalSince(start) * 1000)\n"
            try? await file.close()
            try await client.close()
        } catch {
            log += "DIAG-THREW:\(error)\n"
        }
        try log.write(to: URL(fileURLWithPath: "/tmp/diagpool.txt"), atomically: true, encoding: .utf8)
    }

    /// P1 repro: single pool case through the runner dies in first openFile
    /// ("pool-transfer: I/O on closed channel") while the identical pool +
    /// transfer succeeds standalone. Keep until the pool stability P1 lands.
    func testDiagPoolRunnerRepro() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let store = Self.store
        let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
        let endpoint = SFTPMatrixEndpoint(
            label: "poolrepro", serverType: "openssh-linux-alpine",
            remoteBasePath: "/tmp/bench", localScratchDir: scratch,
            makeSession: { backend in
                let endpoint = SSHEndpoint(host: "127.0.0.1", port: 2222)
                switch backend {
                case .compatibility:
                    let session = CompatibilitySSHSession(
                        backend: try OpenSSHBackend(config: cfg), endpoint: endpoint
                    )
                    return session as any SSHSession
                case .native:
                    let client = try await Self.nativeClient(config: cfg)
                    let session = NativeSSHSession(
                        client: client, endpoint: endpoint, config: cfg, hostKeyStore: store
                    )
                    return session as any SSHSession
                }
            },
            makeCitadelSFTP: { try await Self.nativeClient(config: cfg).openSFTP() as Any },
            makePool: { count in try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: store, count: count) }
        )
        let eightMB: UInt64 = 8 * 1024 * 1024
        let cases: [SFTPMatrixCase] = [
            SFTPMatrixCase(sizeBytes: eightMB, backend: .citadel, mode: .multiTCP, shards: 2, kind: .write),
        ]
        let report = await SFTPMatrixRunner().run(endpoint: endpoint, cases: cases, timeoutSeconds: 300)
        var log = ""
        for row in report.rows {
            log += "\(row.kind)/\(row.backend)/\(row.mode)/\(row.shards) ok=\(row.succeeded) err=\(row.error ?? "-")\n"
        }
        try log.write(to: URL(fileURLWithPath: "/tmp/diagpool.txt"), atomically: true, encoding: .utf8)
    }

    func testLocalMatrixSmoke() async throws {
        try XCTSkipUnless(
            tcpOpen(port: 2222),
            "bench-linux (127.0.0.1:2222) absent — start local bench containers first"
        )
        let runner = SFTPMatrixRunner()
        let endpoint = endpoint(port: 2222, label: "loopback", serverType: "openssh-linux-alpine")
        let eightMB: UInt64 = 8 * 1024 * 1024
        let cases: [SFTPMatrixCase] = [
            SFTPMatrixCase(sizeBytes: eightMB, backend: .openSSH, mode: .singleStream, kind: .write),
            SFTPMatrixCase(sizeBytes: eightMB, backend: .openSSH, mode: .singleStream, kind: .read),
            SFTPMatrixCase(sizeBytes: eightMB, backend: .citadel, mode: .singleStream, shards: 1, kind: .write),
            SFTPMatrixCase(sizeBytes: eightMB, backend: .citadel, mode: .multiChannel, shards: 2, kind: .write),
            SFTPMatrixCase(sizeBytes: eightMB, backend: .citadel, mode: .multiChannel, shards: 4, kind: .write),
        ]
        let report = await runner.run(endpoint: endpoint, cases: cases, timeoutSeconds: 600)
        let csvURL = URL(fileURLWithPath: "/tmp/bench_matrix_smoke.csv")
        try report.csv().write(to: csvURL, atomically: true, encoding: .utf8)
        print(report.markdown())
        print("CSV: \(csvURL.path)")
        for row in report.rows {
            XCTAssertNil(row.skippedReason, "case should run, not skip: \(row.backend)/\(row.mode)/\(row.shards)")
            XCTAssertTrue(
                row.succeeded,
                "case failed: \(row.backend)/\(row.mode)/\(row.shards) kind=\(row.kind) error=\(row.error ?? "?")"
            )
            XCTAssertNotNil(row.effectiveMBps, "no throughput measured")
        }
        XCTAssertEqual(report.rows.count, cases.count)
    }
}
