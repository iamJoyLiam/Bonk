//
//  PerformanceMonitor.swift
//  Bonk
//
//  Performance monitoring utilities for tracking app performance.
//

import Foundation
import os.log

/// Performance monitoring utilities.
enum PerformanceMonitor {
    private static let logger = Logger(subsystem: "com.bonk", category: "Performance")

    /// Measure execution time of a block.
    static func measureTime<T>(label: String, block: () throws -> T) rethrows -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("[\(label)] \(String(format: "%.2f", timeElapsed * 1000))ms")
        return result
    }

    /// Measure execution time of an async block.
    static func measureTimeAsync<T>(label: String, block: () async throws -> T) async rethrows -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await block()
        let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("[\(label)] \(String(format: "%.2f", timeElapsed * 1000))ms")
        return result
    }

    /// Log memory usage.
    static func logMemoryUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1024 / 1024
            logger.info("Memory usage: \(String(format: "%.1f", usedMB)) MB")
        }
    }

    /// Log CPU usage.
    static func logCPUUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            let userTime = info.user_time.seconds
            let systemTime = info.system_time.seconds
            logger.info("CPU time: user=\(String(format: "%.2f", userTime))s, system=\(String(format: "%.2f", systemTime))s")
        }
    }
}

// MARK: - Extensions

extension mach_timebase_info_data_t {
    var seconds: Double {
        Double(numer) / Double(denom) / 1_000_000_000
    }
}
