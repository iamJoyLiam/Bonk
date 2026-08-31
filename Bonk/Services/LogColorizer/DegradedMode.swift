//
//  DegradedMode.swift
//  Bonk — Final Architecture: Degraded Mode
//
//  When log flood is high, protect Terminal rendering/input/SSH.
//

import Foundation
import os

final class DegradedMode: @unchecked Sendable {
    nonisolated(unsafe) static let shared = DegradedMode()

    // Fixed-window counter — O(1), zero allocation per call.
    // Replaces previous [Date] array which did O(N) append+filter on MainActor per chunk.
    private struct WindowState {
        var count: Int = 0
        var windowStart: Date = Date()
        var totalCount: Int = 0 // deterministic sampling counter
    }
    private let state = OSAllocatedUnfairLock<WindowState>(uncheckedState: WindowState())
    private let windowSeconds: TimeInterval = 1.0
    private let fullThreshold = 5000 // lines/sec -> reduced (1/10 sampling)
    private let disableThreshold = 50000 // lines/sec -> disabled

    enum Mode { case full, reduced, disabled }

    var current: Mode {
        state.withLock { windowState in
            let now = Date()
            if now.timeIntervalSince(windowState.windowStart) >= windowSeconds {
                return .full
            }
            let windowCount = windowState.count
            if windowCount >= disableThreshold { return .disabled }
            if windowCount >= fullThreshold { return .reduced }
            return .full
        }
    }

    /// Returns true when decoration should be skipped (feed raw, keep VT bytes intact).
    /// Never drops bytes — only skips regex coloring at the decoration layer.
    func shouldDropLogHighlight(lineCount: Int) -> Bool {
        let (windowCount, totalSampleCount): (Int, Int) = state.withLock { windowState in
            let now = Date()
            if now.timeIntervalSince(windowState.windowStart) >= windowSeconds {
                windowState.count = 0
                windowState.windowStart = now
            }
            windowState.count += lineCount
            windowState.totalCount &+= lineCount
            return (windowState.count, windowState.totalCount)
        }
        if windowCount >= disableThreshold { return true }
        if windowCount >= fullThreshold { return totalSampleCount % 10 != 0 } // 1/10 sampling
        return false
    }

    func reset() {
        state.withLock { windowState in
            windowState.count = 0
            windowState.windowStart = Date()
        }
    }
}
