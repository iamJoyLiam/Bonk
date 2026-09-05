//  InlineMetrics.swift
//  Bonk
//
//  Performance telemetry tracking latency across the inline intelligence pipeline.
//

import Foundation
import os

/// Performance telemetry tracking latency across the inline intelligence pipeline.
public struct InlineMetrics: Sendable {
    public private(set) var keyPressedAt: Date?
    public private(set) var candidateProducedAt: Date?
    public private(set) var renderCompletedAt: Date?

    public init(keyPressedAt: Date? = Date()) {
        self.keyPressedAt = keyPressedAt
    }

    public mutating func markCandidateProduced() {
        self.candidateProducedAt = Date()
    }

    public mutating func markRenderCompleted() {
        self.renderCompletedAt = Date()
    }

    /// Latency from keystroke to candidate generation in milliseconds.
    public var computeLatencyMs: Double? {
        guard let start = keyPressedAt, let end = candidateProducedAt else { return nil }
        return end.timeIntervalSince(start) * 1000.0
    }

    /// Latency from keystroke to UI overlay completion in milliseconds.
    public var totalLatencyMs: Double? {
        guard let start = keyPressedAt, let end = renderCompletedAt ?? candidateProducedAt else { return nil }
        return end.timeIntervalSince(start) * 1000.0
    }

    public func logIfSlow(thresholdMs: Double = 50.0, category: String = "Inline") {
        if let total = totalLatencyMs, total > thresholdMs {
            os_log(
                .default,
                "[InlineMetrics] %{public}@ latency: %.1f ms (compute: %.1f ms)",
                category,
                total,
                computeLatencyMs ?? 0.0
            )
        }
    }
}
