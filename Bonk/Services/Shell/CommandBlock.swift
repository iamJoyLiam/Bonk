//
//  CommandBlock.swift
//  Bonk – Warp-style grouped command output (M7 #14)
//

import Foundation

struct CommandBlock: Identifiable, Sendable, Equatable {
    let id: UUID
    let command: String
    var output: String
    let startTime: Date
    var endTime: Date?
    var exitCode: Int?
    var startChunkIndex: Int
    var endChunkIndex: Int?

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var isSuccessful: Bool { exitCode == 0 }
}

extension CommandBlock {
    var durationLabel: String {
        guard let d = duration else { return "" }
        if d < 1 { return String(format: "%.0fms", d * 1000) }
        if d < 60 { return String(format: "%.1fs", d) }
        return String(format: "%.0fm%.0fs", floor(d / 60), d.truncatingRemainder(dividingBy: 60))
    }
}
