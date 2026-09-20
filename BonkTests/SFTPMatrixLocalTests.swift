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

final class SFTPMatrixLocalTests: XCTestCase {
    private static let password = "benchpass"
    private static let store = AcceptAllHostKeyStore()

    private func config(port: UInt16) -> SSHConnectionConfig {
        SSHConnectionConfig(
            host: "127.0.0.1", port: port,
            username: "root", authMethod: .password(Self.password)
        )
    }

    private static func nativeClient(config: SSHConnectionConfig) async throws -> SSHClient {
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
                    return NativeSSHSession(client: client, endpoint: endpoint, config: cfg, hostKeyStore: store) as any SSHSession
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

    func testLocalMatrixSmoke() async throws {        try XCTSkipUnless(
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
            XCTAssertTrue(row.succeeded, "case failed: \(row.backend)/\(row.mode)/\(row.shards) kind=\(row.kind) error=\(row.error ?? "?")")
            XCTAssertNotNil(row.effectiveMBps, "no throughput measured")
        }
        XCTAssertEqual(report.rows.count, cases.count)
    }
}
