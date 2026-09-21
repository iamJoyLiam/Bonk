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

/// Commit-3: recording pool factory for execution assertions.
/// Wraps the real factory; records shard counts per profile.
private actor RecordingPoolFactory: SFTPPoolFactory {
    private(set) var shardsUsed: [Int] = []
    private let real = DefaultSFTPPoolFactory()
    func makePool(configuration: SFTPPoolConfiguration) async throws -> [PooledSFTPHandle] {
        shardsUsed.append(configuration.shards)
        return try await real.makePool(configuration: configuration)
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
            algorithms: .all,
            protocolOptions: [.maximumPacketSize(SFTPChannelTuning.windowBytes)]
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
    /// NOTE: pool cells run via the `pool` flag (fixed: pool handles are now
    /// owned at function scope so the close-defer fires after the transfer).
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

    // Pool cells ride the multi branch via poolMultiCell (batch.pool flag).

    private func multiCell(
        size: UInt64, kind: SFTPMatrixKind, backend: SFTPMatrixBackend, shards: Int
    ) -> SFTPMatrixCase {
        let mode: SFTPMatrixMode = backend == .openSSH ? .singleStream : .multiChannel
        return SFTPMatrixCase(sizeBytes: size, backend: backend, mode: mode, shards: shards, kind: kind)
    }

    private func poolMultiCell(size: UInt64, kind: SFTPMatrixKind) -> SFTPMatrixCase {
        SFTPMatrixCase(sizeBytes: size, backend: .citadel, mode: .multiTCP, shards: 4, kind: kind)
    }

    /// Regression: pool-owned handles must survive until the transfer ends.
    /// Root cause was a defer inside the acquisition branch firing at branch
    /// exit (before use), racing the engine and closing the pool mid-flight
    /// ('pool-transfer: Output closed' / 'I/O on closed channel').
    func testPoolViaRunnerSucceeds() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let store = Self.store
        let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
        let endpoint = SFTPMatrixEndpoint(
            label: "poolregression", serverType: "openssh-linux-alpine",
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
            SFTPMatrixCase(sizeBytes: eightMB, backend: .citadel, mode: .multiTCP, shards: 2, kind: .read),
        ]
        let report = await SFTPMatrixRunner().run(endpoint: endpoint, cases: cases, timeoutSeconds: 300)
        XCTAssertEqual(report.rows.count, 2)
        for row in report.rows {
            XCTAssertTrue(row.succeeded, "pool via runner failed: \(row.error ?? "-")")
        }
    }

    /// Planner decision runs inside the real adapter chain
    /// (upload/download through CitadelSFTPAdapter). Execution unchanged.
    /// A stub provider stands in for the session cache: proves a measured
    /// RTT reaches the decision (see [PLANNER] in unified log).
    func testAdapterPlannerDecisionPath() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let client = try await Self.nativeClient(config: cfg)
        let sftp = try await client.openSFTP()
        struct StubRTT: SFTPRTTProvider { func currentRTTMs() -> Double? { 30 } }
        let adapter = CitadelSFTPAdapter(sftp: sftp, rttProvider: StubRTT())
        let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
        let local = scratch.appendingPathComponent("payload_8388608.bin")
        let remote = "/tmp/bench/planner_smoke_\(Int(Date().timeIntervalSince1970)).bin"
        let dest = scratch.appendingPathComponent("planner_smoke_dl.bin")
        try? FileManager.default.removeItem(at: dest)
        let progress: @Sendable (Double) -> Void = { _ in }
        try await adapter.upload(local, to: remote, operationID: UUID(), onProgress: progress)
        try await adapter.download(remote, to: dest, operationID: UUID(), onProgress: progress)
        let got = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
        XCTAssertEqual(got, 8 * 1024 * 1024)
        try? FileManager.default.removeItem(at: dest)
        // 512MB through the same chain: decision must read accelerated.
        let big = scratch.appendingPathComponent("payload_536870912.bin")
        let bigRemote = "/tmp/bench/planner_smoke_512_\(Int(Date().timeIntervalSince1970)).bin"
        try await adapter.upload(big, to: bigRemote, operationID: UUID(), onProgress: progress)
        try? await sftp.close()
        try? await client.close()
    }

    /// Fallback chain: pool unreachable -> multiChannel still succeeds
    /// (production adapter path, no pool ever blocks a transfer).
    func testAdapterPoolFallback() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let client = try await Self.nativeClient(config: cfg)
        let sftp = try await client.openSFTP()
        let badCfg = SSHConnectionConfig(host: "127.0.0.1", port: 22999, username: "root", authMethod: .password(Self.password))
        let adapter = CitadelSFTPAdapter(sftp: sftp, pooledConfig: badCfg, pooledStore: Self.store)
        let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
        // 512MB forces the pool branch (mid-band high-RTT -> accelerated);
        // the bad port fails fast, proving pool -> multiChannel fallback.
        let local = scratch.appendingPathComponent("payload_536870912.bin")
        let remote = "/tmp/bench/fallback_\(Int(Date().timeIntervalSince1970)).bin"
        let progress: @Sendable (Double) -> Void = { _ in }
        try await adapter.upload(local, to: remote, operationID: UUID(), onProgress: progress)
        try? await sftp.close()
        try? await client.close()
    }

    /// Hard gate before PoolFactory: real SSH connect -> real SFTP
    /// connect -> real RTT probe -> session cache -> planner. No os.log
    /// dependency: every step below is an asserted state transition.
    func testSessionRTTLiveFire() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let ssh = SSHNetworkService(hostKeyStore: Self.store)
        try await ssh.connect(config: cfg)
        let service = await MainActor.run { SFTPService() }
        try await service.connect(using: ssh)
        // Cache filled by a real probe (not nil, positive).
        let rtt = await MainActor.run { service.sessionRTT.currentRTTMs() }
        guard let rtt else {
            XCTFail("RTT cache empty after live connect"); return
        }
        XCTAssertGreaterThan(rtt, 0)
        // The cached value feeds the planner: loopback RTT is low, so a
        // 2GB read must resolve to accelerated (campaign anchor).
        let profile = SFTPTransferPlanner.profile(
            sizeBytes: 2 * 1024 * 1024 * 1024, rttMs: rtt, operation: .read
        )
        XCTAssertEqual(profile, .accelerated)
        // Second read reuses the snapshot (probe ran once at connect).
        let again = await MainActor.run { service.sessionRTT.currentRTTMs() }
        XCTAssertEqual(again, rtt)
        await service.disconnect()
        await ssh.disconnect()
    }

    /// Service-level fallback gate: a poisoned TOFU fingerprint kills
    /// Citadel only (hostKeyMismatch); the default automatic backend
    /// (Citadel-first) must still connect via OpenSSH and transfer,
    /// with no Citadel error surfacing.
    /// The shared store is restored before return (real fp captured first
    /// with a throwaway store, so order with other tests does not matter).
    func testServiceCitadelToOpenSSHallback() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let probeStore = AcceptAllHostKeyStore()
        let probePool = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: probeStore, count: 1)
        for handle in probePool { await handle.close() }
        guard let realFP = await probeStore.knownFingerprint(for: "127.0.0.1", port: 2222) else {
            XCTFail("no fingerprint captured"); return
        }
        await Self.store.saveFingerprint(
            SSHHostFingerprint(hash: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            for: "127.0.0.1", port: 2222
        )
        do {
            // Negative control: Citadel is really dead under poison.
            do {
                let dead = try await SFTPMultiTCPPool.makePool(config: cfg, hostKeyStore: Self.store, count: 1)
                for handle in dead { await handle.close() }
                XCTFail("Citadel unexpectedly survived poison")
            } catch {
                // Expected: hostKeyMismatch. Fallback must cover this.
            }
            let ssh = SSHNetworkService(hostKeyStore: Self.store)
            try await ssh.connect(config: cfg)
            let service = await MainActor.run { SFTPService() }
            // Default automatic backend is Citadel-first: poison forces the
            // OpenSSH fallback leg.
            await MainActor.run { service.preferredBackend = .automatic }
            try await service.connect(using: ssh)
            // Fallback served by OpenSSH: no Citadel error surfaces.
            let errMessage = await MainActor.run { service.errorMessage }
            XCTAssertNil(errMessage)
            // Real transfer through the fallback channel.
            let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
            let local = scratch.appendingPathComponent("payload_8388608.bin")
            let remote = "/tmp/bench/fbfallback_\(Int(Date().timeIntervalSince1970)).bin"
            for try await _ in await MainActor.run { service.upload(local, to: remote) } {}
            let dest = scratch.appendingPathComponent("fbfallback_dl.bin")
            try? FileManager.default.removeItem(at: dest)
            try await service.download(SFTPFileEntry(id: remote, name: "fbfallback.bin", path: remote, isDirectory: false, size: 8 * 1024 * 1024, permissions: 0o644, modifiedAt: nil, longname: ""), to: dest)
            let got = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
            XCTAssertEqual(got, 8 * 1024 * 1024)
            try? FileManager.default.removeItem(at: dest)
            await service.disconnect()
            await ssh.disconnect()
        } catch {
            await Self.store.saveFingerprint(realFP, for: "127.0.0.1", port: 2222)
            throw error
        }
        await Self.store.saveFingerprint(realFP, for: "127.0.0.1", port: 2222)
    }

    /// Commit-3 gate: planner decisions really execute mc2/mc4 pools
    /// in production (adapter + injected factory). A recording factory
    /// wraps the real one and asserts the shard counts per profile.
    func testPlannerDrivenPoolExecution() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let client = try await Self.nativeClient(config: cfg)
        let sftp = try await client.openSFTP()
        struct LowRTT: SFTPRTTProvider { func currentRTTMs() -> Double? { 0 } }
        struct HighRTT: SFTPRTTProvider { func currentRTTMs() -> Double? { 30 } }
        let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
        let progress: @Sendable (Double) -> Void = { _ in }
        let ts = Int(Date().timeIntervalSince1970)
        func payload(_ bytes: UInt64) -> URL {
            scratch.appendingPathComponent("payload_\(bytes).bin")
        }
        // 1. compatibility: 8MB never touches the factory.
        do {
            let spy = RecordingPoolFactory()
            let adapter = CitadelSFTPAdapter(sftp: sftp, pooledConfig: cfg, pooledStore: Self.store, rttProvider: HighRTT(), poolFactory: spy)
            try await adapter.upload(payload(8 * 1024 * 1024), to: "/tmp/bench/exec8_\(ts).bin", operationID: UUID(), onProgress: progress)
            let used0 = await spy.shardsUsed
            XCTAssertTrue(used0.isEmpty)
        }
        // 2. balanced write 512MB low-RTT -> mc2.
        do {
            let spy = RecordingPoolFactory()
            let adapter = CitadelSFTPAdapter(sftp: sftp, pooledConfig: cfg, pooledStore: Self.store, rttProvider: LowRTT(), poolFactory: spy)
            try await adapter.upload(payload(512 * 1024 * 1024), to: "/tmp/bench/execw512_\(ts).bin", operationID: UUID(), onProgress: progress)
            let used = await spy.shardsUsed
            XCTAssertEqual(used, [2])
        }
        // 3. accelerated write 512MB high-RTT -> mc4.
        do {
            let spy = RecordingPoolFactory()
            let adapter = CitadelSFTPAdapter(sftp: sftp, pooledConfig: cfg, pooledStore: Self.store, rttProvider: HighRTT(), poolFactory: spy)
            try await adapter.upload(payload(512 * 1024 * 1024), to: "/tmp/bench/execw512h_\(ts).bin", operationID: UUID(), onProgress: progress)
            let used = await spy.shardsUsed
            XCTAssertEqual(used, [4])
        }
        // 4. balanced write 2GB low-RTT -> mc2.
        do {
            let spy = RecordingPoolFactory()
            let adapter = CitadelSFTPAdapter(sftp: sftp, pooledConfig: cfg, pooledStore: Self.store, rttProvider: LowRTT(), poolFactory: spy)
            try await adapter.upload(payload(2 * 1024 * 1024 * 1024), to: "/tmp/bench/execw2g_\(ts).bin", operationID: UUID(), onProgress: progress)
            let used = await spy.shardsUsed
            XCTAssertEqual(used, [2])
        }
        // 5. accelerated read 2GB: fixture upload + download, both mc4.
        do {
            let spy = RecordingPoolFactory()
            let adapter = CitadelSFTPAdapter(sftp: sftp, pooledConfig: cfg, pooledStore: Self.store, rttProvider: HighRTT(), poolFactory: spy)
            let remote = "/tmp/bench/execr2g_\(ts).bin"
            try await adapter.upload(payload(2 * 1024 * 1024 * 1024), to: remote, operationID: UUID(), onProgress: progress)
            let dest = scratch.appendingPathComponent("execr2g_dl_\(ts).bin")
            try? FileManager.default.removeItem(at: dest)
            try await adapter.download(remote, to: dest, operationID: UUID(), onProgress: progress)
            let used = await spy.shardsUsed
            XCTAssertEqual(used, [4, 4])
            try? FileManager.default.removeItem(at: dest)
        }
        // 6. balanced read 512MB low-RTT: fixture + download, both mc2.
        do {
            let spy = RecordingPoolFactory()
            let adapter = CitadelSFTPAdapter(sftp: sftp, pooledConfig: cfg, pooledStore: Self.store, rttProvider: LowRTT(), poolFactory: spy)
            let remote = "/tmp/bench/execr512_\(ts).bin"
            try await adapter.upload(payload(512 * 1024 * 1024), to: remote, operationID: UUID(), onProgress: progress)
            let dest = scratch.appendingPathComponent("execr512_dl_\(ts).bin")
            try? FileManager.default.removeItem(at: dest)
            try await adapter.download(remote, to: dest, operationID: UUID(), onProgress: progress)
            let used = await spy.shardsUsed
            XCTAssertEqual(used, [2, 2])
            try? FileManager.default.removeItem(at: dest)
        }
        try? await sftp.close()
        try? await client.close()
    }

    /// Correctness: re-uploading an existing destination must replace
    /// it (no half-finished state, repeatable). Covers verifyAndRenameRemote.
    func testReuploadExistingDestination() async throws {
        try XCTSkipUnless(tcpOpen(port: 2222), "bench-linux absent")
        let cfg = config(port: 2222)
        let client = try await Self.nativeClient(config: cfg)
        let sftp = try await client.openSFTP()
        let adapter = CitadelSFTPAdapter(sftp: sftp)
        let scratch = URL(fileURLWithPath: "/tmp/bench_scratch_2222", isDirectory: true)
        let local = scratch.appendingPathComponent("payload_8388608.bin")
        let remote = "/tmp/bench/reupload_\(Int(Date().timeIntervalSince1970)).bin"
        let progress: @Sendable (Double) -> Void = { _ in }
        // First upload creates the destination.
        try await adapter.upload(local, to: remote, operationID: UUID(), onProgress: progress)
        // Second identical upload must replace, not fail.
        try await adapter.upload(local, to: remote, operationID: UUID(), onProgress: progress)
        // Third upload: repeat stability.
        try await adapter.upload(local, to: remote, operationID: UUID(), onProgress: progress)
        // Content intact.
        let dest = scratch.appendingPathComponent("reupload_dl.bin")
        try? FileManager.default.removeItem(at: dest)
        try await adapter.download(remote, to: dest, operationID: UUID(), onProgress: progress)
        let got = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
        XCTAssertEqual(got, 8 * 1024 * 1024)
        try? FileManager.default.removeItem(at: dest)
        try? await sftp.close()
        try? await client.close()
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
