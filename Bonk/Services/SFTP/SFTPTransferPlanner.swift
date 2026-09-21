//
//  SFTPTransferPlanner.swift
//  Bonk
//
//  Adaptive Transfer Profile: maps (size, RTT, operation) to a transfer
//  profile. Pure function — RTT is injected (production caches it per
//  session at connect time). Thresholds come from the Phase A benchmark
//  campaign (see /tmp/bench_matrix_full.csv):
//  - Small files (<256MB): pool setup outweighs any gain, both RTTs.
//  - Large reads (>=512MB): mc4 wins at rtt0 (1.24x) and rtt30 (1.83x).
//  - Large writes: flat at rtt0 (mc2 ~= mc4), 1.89x at rtt30.
//  mc8 regressed everywhere (read 2GB mc4 745 -> mc8 509): stress only.
//

import Foundation
import NIOConcurrencyHelpers

/// Planner input: session round-trip time in milliseconds, if measured.
/// The planner never probes; production caches one measurement per fresh
/// connection (Commit-2) and reuses it for the session lifetime.
protocol SFTPRTTProvider: Sendable {
    func currentRTTMs() -> Double?
}

/// One-shot session RTT snapshot. Probed once per fresh connection, read
/// synchronously after that — repeated reads never re-probe.
final class SFTPSessionRTTCache: SFTPRTTProvider, @unchecked Sendable {
    private let box = NIOLockedValueBox<Double?>(nil)

    func currentRTTMs() -> Double? {
        box.withLockedValue { $0 }
    }

    /// Clears the snapshot (fresh connection establishes a new session).
    func reset() {
        box.withLockedValue { $0 = nil }
    }

    /// Runs probe at most once (no-op once a value is cached). Never throws
    /// and never blocks SFTP: probe failure or a nil result leaves the
    /// cache empty, and the planner falls back to its nil-RTT branch.
    func refreshIfNeeded(probe: @Sendable () async -> Double?) async {
        if currentRTTMs() != nil { return }
        let measured = await probe()
        box.withLockedValue { current in
            if current == nil { current = measured }
        }
    }
}

/// Worker profile for one transfer. Names the profile, not the engine.
/// All profiles run on Citadel (preferred engine): compatibility is
/// Citadel single-stream with zero pool overhead; balanced/accelerated
/// build Citadel mc2/mc4 pools. OpenSSH is not a profile — it is the
/// compatibility fallback engine below Citadel.
enum SFTPTransferProfile: String, Sendable, Equatable {
    case compatibility
    case balanced
    case accelerated

    /// Fixed planner-to-factory mapping (Commit-3). mc8 stays stress-only
    /// and never appears here. nil means single-stream, no pool.
    var poolShards: Int? {
        switch self {
        case .compatibility: return nil
        case .balanced: return 2
        case .accelerated: return 4
        }
    }
}

/// Transfer direction. Reads and writes scale differently with RTT
/// (writes only benefit from pooling on higher-RTT links).
enum SFTPTransferOperation: Sendable {
    case read
    case write
}

enum SFTPTransferPlanner {
    /// Below this RTT the link counts as low-latency.
    static let lowRTTThresholdMs = 10.0
    /// Pool setup outweighs gains below this size (both RTTs, both ops).
    static let smallFileBytes: UInt64 = 256 * 1024 * 1024
    /// Above this size reads always take the accelerated profile.
    static let largeFileBytes: UInt64 = 1024 * 1024 * 1024

    /// Select the profile for one transfer.
    /// - Parameters:
    ///   - sizeBytes: payload size.
    ///   - rttMs: session-cached round-trip time. nil (unmeasured) takes
    ///     the high-RTT branch: for large payloads mc4 never loses
    ///     (ties rtt0 writes, wins everywhere else).
    ///   - operation: read or write.
    static func profile(
        sizeBytes: UInt64,
        rttMs: Double?,
        operation: SFTPTransferOperation
    ) -> SFTPTransferProfile {
        let highRTT = (rttMs ?? .infinity) >= lowRTTThresholdMs
        if sizeBytes < smallFileBytes {
            return .compatibility
        }
        if sizeBytes > largeFileBytes {
            if operation == .read {
                return .accelerated
            }
            return highRTT ? .accelerated : .balanced
        }
        // Mid band 256MB...1GB: pool only pays off when RTT is high.
        return highRTT ? .accelerated : .balanced
    }
}
