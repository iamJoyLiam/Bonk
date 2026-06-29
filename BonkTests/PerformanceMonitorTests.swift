//
//  PerformanceMonitorTests.swift
//  BonkTests
//
//  Tests for PerformanceMonitor functionality.
//

import XCTest
@testable import Bonk

final class PerformanceMonitorTests: XCTestCase {

    // MARK: - Measure Time

    func testMeasureTimeReturnsResult() {
        let result = PerformanceMonitor.measureTime(label: "test") {
            return 42
        }
        XCTAssertEqual(result, 42)
    }

    func testMeasureTimeMeasuresExecution() {
        let startTime = CFAbsoluteTimeGetCurrent()
        _ = PerformanceMonitor.measureTime(label: "test") {
            // Simulate some work
            Thread.sleep(forTimeInterval: 0.01)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        XCTAssertGreaterThanOrEqual(elapsed, 0.01)
    }

    // MARK: - Memory Usage

    func testLogMemoryUsageDoesNotCrash() {
        // This should not crash
        PerformanceMonitor.logMemoryUsage()
    }

    // MARK: - CPU Usage

    func testLogCPUUsageDoesNotCrash() {
        // This should not crash
        PerformanceMonitor.logCPUUsage()
    }
}
