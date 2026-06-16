//
//  CrashReporter.swift
//  Bonk
//
//  Catches uncaught exceptions and writes crash logs to disk.
//

import Foundation
import os.log

enum CrashReporter {
    private static let logDir: URL = {
        guard let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            fatalError("Unable to locate user Library directory")
        }
        let dir = base.appendingPathComponent("Logs/Bonk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Install uncaught exception handler. Call once at app launch.
    static func install() {
        NSSetUncaughtExceptionHandler(handleException)
        Log.general.info("CrashReporter installed")
    }

    private static let handleException: @convention(c) (NSException) -> Void = { exception in
        writeCrashLog(exception: exception)
    }

    private static func writeCrashLog(exception: NSException) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "crash-\(timestamp).log"
        let url = logDir.appendingPathComponent(filename)

        let lines = [
            "Timestamp: \(timestamp)",
            "Exception: \(exception.name.rawValue)",
            "Reason: \(exception.reason ?? "unknown")",
            "Stack:",
            exception.callStackSymbols.joined(separator: "\n"),
        ]

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)

        Log.general.error("CRASH: \(exception.name.rawValue) — \(exception.reason ?? "unknown")")
    }
}
