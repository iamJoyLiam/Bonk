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

    private var counter: Int = 0
    func shouldDropLogHighlight(lineCount: Int) -> Bool {
        lock.lock()
        let now = Date()
        for _ in 0..<lineCount { lineCountWindow.append(now) }
        lineCountWindow = lineCountWindow.filter { now.timeIntervalSince($0) < windowSeconds }
        let c = lineCountWindow.count
        counter &+= lineCount
        let n = counter
        lock.unlock()
        if c >= disableThreshold { return true }
        if c >= fullThreshold { return n % 10 != 0 } // deterministic 1/10 sampling
        return false
    }

    func reset() {
        lock.lock()
        lineCountWindow.removeAll()
        lock.unlock()
    }
}
