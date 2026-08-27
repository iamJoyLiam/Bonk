//
//  DegradedMode.swift
//  Bonk — Final Architecture: Degraded Mode
//
//  When log flood is high, protect Terminal rendering/input/SSH.
//

import Foundation

final class DegradedMode: @unchecked Sendable {
    nonisolated(unsafe) static let shared = DegradedMode()

    private var lineCountWindow: [Date] = []
    private let lock = NSLock()
    private let windowSeconds: TimeInterval = 1.0
    private let fullThreshold = 5000 // lines/sec -> reduced
    private let disableThreshold = 50000 // lines/sec -> disabled

    enum Mode { case full, reduced, disabled }

    var current: Mode {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        lineCountWindow = lineCountWindow.filter { now.timeIntervalSince($0) < windowSeconds }
        let c = lineCountWindow.count
        if c >= disableThreshold { return .disabled }
        if c >= fullThreshold { return .reduced }
        return .full
    }

    func shouldDropLogHighlight(lineCount: Int) -> Bool {
        lock.lock()
        let now = Date()
        for _ in 0..<lineCount { lineCountWindow.append(now) }
        // Trim old
        lineCountWindow = lineCountWindow.filter { now.timeIntervalSince($0) < windowSeconds }
        let c = lineCountWindow.count
        lock.unlock()
        if c >= disableThreshold { return true } // drop all log highlight, keep terminal
        if c >= fullThreshold {
            // Reduced: only highlight every 10th line
            return Int.random(in: 0..<10) != 0
        }
        return false
    }

    func reset() {
        lock.lock()
        lineCountWindow.removeAll()
        lock.unlock()
    }
}
