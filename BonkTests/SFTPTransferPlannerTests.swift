//
//  SFTPTransferPlannerTests.swift
//  BonkTests — strategy table as executable spec (Phase A campaign).
//

import XCTest
@testable import Bonk

final class SFTPTransferPlannerTests: XCTestCase {
    private struct Vector {
        let size: UInt64
        let rtt: Double?
        let op: SFTPTransferOperation
        let expect: SFTPTransferProfile
    }

    private static let mb: UInt64 = 1024 * 1024
    private static let gb: UInt64 = 1024 * 1024 * 1024

    /// Every cell of the strategy table, both operations.
    private static let table: [Vector] = {
        var v: [Vector] = []
        // Size classes: tiny, just-below-256MB, boundary 256MB, mid,
        // boundary 1GB, just-above-1GB, 2GB.
        let sizes: [UInt64] = [0, 1 * mb, 255 * mb, 256 * mb, 512 * mb, 1 * gb, gb + 1, 2 * gb]
        // RTT classes: unmeasured, low, boundary 10ms, high.
        let rtts: [Double?] = [nil, 0, 5, 9.9, 10, 30, 200]
        for size in sizes {
            for rtt in rtts {
                for op in [SFTPTransferOperation.read, SFTPTransferOperation.write] {
                    v.append(Vector(size: size, rtt: rtt, op: op, expect: expected(size: size, rtt: rtt, op: op)))
                }
            }
        }
        return v
    }()

    /// Independent oracle mirroring the published strategy table
    /// (not the implementation).
    private static func expected(size: UInt64, rtt: Double?, op: SFTPTransferOperation) -> SFTPTransferProfile {
        let highRTT = (rtt ?? .infinity) >= 10.0
        if size < 256 * mb { return .compatibility }
        if size > 1 * gb {
            if op == .read { return .accelerated }
            return highRTT ? .accelerated : .balanced
        }
        return highRTT ? .accelerated : .balanced
    }

    func testStrategyTable() {
        for cell in Self.table {
            XCTAssertEqual(
                SFTPTransferPlanner.profile(sizeBytes: cell.size, rttMs: cell.rtt, operation: cell.op),
                cell.expect,
                "size=\(cell.size) rtt=\(String(describing: cell.rtt)) op=\(cell.op)"
            )
        }
    }

    // MARK: - Commit-2: RTTProvider + session cache

    private struct StubProvider: SFTPRTTProvider {
        let rtt: Double?
        func currentRTTMs() -> Double? { rtt }
    }

    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func increment() { lock.lock(); _count += 1; lock.unlock() }
    }

    func testProviderValueReachesPlanner() {
        // 2GB write: provider 30ms -> accelerated (campaign 73->138).
        let provider: any SFTPRTTProvider = StubProvider(rtt: 30)
        XCTAssertEqual(
            SFTPTransferPlanner.profile(
                sizeBytes: 2 * Self.gb, rttMs: provider.currentRTTMs(), operation: .write
            ),
            .accelerated
        )
    }

    func testNilProviderFallsBack() {
        // No provider -> nil RTT -> existing nil-fallback branch.
        let provider: (any SFTPRTTProvider)? = nil
        XCTAssertEqual(
            SFTPTransferPlanner.profile(
                sizeBytes: 128 * Self.mb, rttMs: provider?.currentRTTMs(), operation: .read
            ),
            .compatibility
        )
    }

    func testCacheProbesOnce() async {
        let cache = SFTPSessionRTTCache()
        let counter = ProbeCounter()
        // Repeated refreshes share one probe result (single call site is
        // connect; the guard makes any repeat free).
        for _ in 0..<4 {
            await cache.refreshIfNeeded {
                counter.increment()
                return 30.0
            }
        }
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(cache.currentRTTMs(), 30)
        // Later refreshes never re-probe.
        let before = counter.count
        await cache.refreshIfNeeded { 99.0 }
        XCTAssertEqual(counter.count, before)
        XCTAssertEqual(cache.currentRTTMs(), 30)
    }

    func testProbeFailureLeavesNilWithoutBlocking() async {
        let cache = SFTPSessionRTTCache()
        // Probe failure is data, not an error: returns normally, stays nil.
        await cache.refreshIfNeeded { nil as Double? }
        XCTAssertNil(cache.currentRTTMs())
        // A later successful probe still fills the cache.
        await cache.refreshIfNeeded { 12.0 }
        XCTAssertEqual(cache.currentRTTMs(), 12)
        cache.reset()
        XCTAssertNil(cache.currentRTTMs())
    }

    func testPoolShardsMapping() {
        XCTAssertNil(SFTPTransferProfile.compatibility.poolShards)
        XCTAssertEqual(SFTPTransferProfile.balanced.poolShards, 2)
        XCTAssertEqual(SFTPTransferProfile.accelerated.poolShards, 4)
    }

    func testEvidenceAnchors() {
        // Campaign anchors that must never regress:
        // - 128MB read rtt30: mc2 122 vs mc4 118 -> no pooling.
        XCTAssertEqual(
            SFTPTransferPlanner.profile(sizeBytes: 128 * Self.mb, rttMs: 30, operation: .read),
            .compatibility
        )
        // - 2GB read rtt0 (601->745) and rtt30 (204->374) -> accelerate.
        XCTAssertEqual(
            SFTPTransferPlanner.profile(sizeBytes: 2 * Self.gb, rttMs: 0, operation: .read),
            .accelerated
        )
        XCTAssertEqual(
            SFTPTransferPlanner.profile(sizeBytes: 2 * Self.gb, rttMs: 30, operation: .read),
            .accelerated
        )
        // - 2GB write rtt0 flat (365~=368) -> balanced; rtt30 (73->138) -> accelerate.
        XCTAssertEqual(
            SFTPTransferPlanner.profile(sizeBytes: 2 * Self.gb, rttMs: 0, operation: .write),
            .balanced
        )
        XCTAssertEqual(
            SFTPTransferPlanner.profile(sizeBytes: 2 * Self.gb, rttMs: 30, operation: .write),
            .accelerated
        )
    }
}
