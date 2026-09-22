//  DecisionTrace.swift
//  Bonk
//
//  Decision Observability Layer (phase 1): every engine judgment leaves a
//  trace. Development reads them via Logger; production aggregates them in
//  the shared recorder (engine × reorder-rate × latency × accepts) so the
//  product can answer "is AI actually better than rules?" with data.
//  Traces never touch the keystroke path — recording is fire-and-forget.

import Foundation
import os

/// One engine judgment: what was decided, how confident, how long it took,
/// and whether it changed the deterministic order (the only thing the user
/// can perceive as "AI working").
///
/// `confidence` is engine-specific — NEVER compare raw values across engines.
/// `confidenceSource` records what the number means ("jev_concentration" vs
/// "laya_top_probability"); calibration buckets in the summary map each
/// source's numbers to observed accept rates.
struct DecisionTrace: Sendable, Equatable {
    let timestamp: Date
    /// Engine label (see DecisionEngine.engineName).
    let engine: String
    /// Candidate count offered to the engine.
    let inputCount: Int
    /// Deterministic top candidate before the engine decided (nil if none).
    let originalTopID: String?
    /// Winner id, or nil when the engine abstained.
    let selectedID: String?
    let confidence: Double
    let confidenceSource: String
    /// Wall-clock judgment latency in milliseconds.
    let latencyMs: Double
    /// True when the winner differs from the deterministic top candidate.
    /// False (or abstain) means the user saw nothing new.
    let changedOrder: Bool
    /// Set when the user accepted the winning suggestion afterwards.
    var accepted: Bool = false

    init(
        engine: String,
        inputCount: Int,
        originalTopID: String? = nil,
        selectedID: String? = nil,
        confidence: Double,
        confidenceSource: String,
        latencyMs: Double,
        changedOrder: Bool,
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.engine = engine
        self.inputCount = inputCount
        self.originalTopID = originalTopID
        self.selectedID = selectedID
        self.confidence = confidence
        self.confidenceSource = confidenceSource
        self.latencyMs = latencyMs
        self.changedOrder = changedOrder
    }
}

/// Per-engine aggregate over recorded traces.
struct DecisionEngineStats: Sendable, Equatable {
    let decisions: Int
    let reorders: Int
    let accepts: Int
    let totalLatencyMs: Double

    var reorderRate: Double {
        decisions > 0 ? Double(reorders) / Double(decisions) : 0
    }

    var meanLatencyMs: Double {
        decisions > 0 ? totalLatencyMs / Double(decisions) : 0
    }
}

/// One confidence bucket for calibration: predicted range vs observed
/// accept rate. Answers "does 90% actually mean 90%?".
struct ConfidenceBucket: Sendable, Equatable {
    /// Bucket lower bound (inclusive), e.g. 0.8 for the 0.8–0.9 bucket.
    let lowerBound: Double
    let decisions: Int
    let accepts: Int

    var acceptRate: Double {
        decisions > 0 ? Double(accepts) / Double(decisions) : 0
    }
}

/// In-memory ring of decision traces. Bounded, lock-free (actor), no I/O.
actor DecisionTraceRecorder {
    static let shared = DecisionTraceRecorder()

    private static let capacity = 200
    private var traces: [DecisionTrace] = []
    private var accepts: [String: Int] = [:]
    /// Agent lifecycle ring (see AgentTraceEvent.swift). Same bound, separate
    /// ring so inline calibration data and agent events never evict each other.
    var agentEvents: [AgentTraceEvent] = []

    func record(_ trace: DecisionTrace) {
        traces.append(trace)
        if traces.count > Self.capacity {
            traces.removeFirst(traces.count - Self.capacity)
        }
    }

    func recordAccept(engine: String, selectedID: String? = nil) {
        accepts[engine, default: 0] += 1
        // Link the outcome to the latest matching undecided trace so
        // calibration buckets measure real accept rates, not raw counts.
        if let id = selectedID,
           let idx = traces.lastIndex(where: { $0.engine == engine && $0.selectedID == id && !$0.accepted }) {
            traces[idx].accepted = true
        } else if selectedID == nil,
                  let idx = traces.lastIndex(where: { $0.engine == engine && !$0.accepted }) {
            traces[idx].accepted = true
        }
    }

    func recentTraces(limit: Int = 20) -> [DecisionTrace] {
        Array(traces.suffix(limit))
    }

    func summary() -> [String: DecisionEngineStats] {
        var stats: [String: DecisionEngineStats] = [:]
        for trace in traces {
            let current = stats[trace.engine, default: DecisionEngineStats(
                decisions: 0, reorders: 0, accepts: 0, totalLatencyMs: 0
            )]
            stats[trace.engine] = DecisionEngineStats(
                decisions: current.decisions + 1,
                reorders: current.reorders + (trace.changedOrder ? 1 : 0),
                accepts: accepts[trace.engine, default: 0],
                totalLatencyMs: current.totalLatencyMs + trace.latencyMs
            )
        }
        for (engine, count) in accepts where stats[engine] == nil {
            stats[engine] = DecisionEngineStats(
                decisions: 0, reorders: 0, accepts: count, totalLatencyMs: 0
            )
        }
        return stats
    }

    func reset() {
        traces = []
        accepts = [:]
    }

    /// Calibration buckets per engine: for each predicted-confidence band,
    /// the observed accept rate. Gaps between band and rate mean the engine
    /// is miscalibrated (and its threshold needs fitting, not guessing).
    func calibrationBuckets() -> [String: [ConfidenceBucket]] {
        var grouped: [String: [DecisionTrace]] = [:]
        for trace in traces {
            grouped[trace.engine, default: []].append(trace)
        }
        var result: [String: [ConfidenceBucket]] = [:]
        for (engine, group) in grouped {
            result[engine] = [0.5, 0.6, 0.7, 0.8, 0.9].map { lower in
                // Top band is closed on the right (confidence 1.0 belongs here).
                let band = group.filter {
                    $0.confidence >= lower && ($0.confidence < lower + 0.1 || lower == 0.9)
                }
                return ConfidenceBucket(
                    lowerBound: lower,
                    decisions: band.count,
                    accepts: band.filter(\.accepted).count
                )
            }
        }
        return result
    }
}
