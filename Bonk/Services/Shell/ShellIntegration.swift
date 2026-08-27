//
//  ShellIntegration.swift
//  Bonk
//
//  Parses OSC 133 (semantic prompt) sequences to track command boundaries.
//  Supports zsh/bash with shell integration (precmd/preexec).
//  OSC 133; A = prompt start, B = prompt end (ready for input), C = command start, D = command end
//

import Foundation
import os.log

struct ShellCommandRange: Identifiable, Sendable {
    let id: UUID
    let startLine: Int
    var endLine: Int?
    let command: String
    let startTime: Date
}

enum ShellEvent: Sendable {
    case promptStart
    case commandStart(ShellCommandRange)
    case commandEnd(ShellCommandRange, exitCode: Int?)
}

final class ShellIntegration {
    private let logger = Logger(subsystem: "com.bonk", category: "Shell")
    private(set) var commands: [ShellCommandRange] = []
    private var current: ShellCommandRange?
    private var lineCounter = 0
    private var pendingCommand = ""
    var onEvent: (@Sendable (ShellEvent) -> Void)?

    /// Returns events emitted while scanning this chunk.
    @discardableResult
    func process(text: String, lineCount: Int) -> [ShellEvent] {
        lineCounter = lineCount
        var events: [ShellEvent] = []
        var remaining = text
        while let escRange = remaining.range(of: "\u{1B}]133;") {
            let after = remaining[escRange.upperBound...]
            var term: String.Index?
            var termLen = 1
            if let bel = after.firstIndex(of: "\u{07}") {
                term = bel
            } else if let esc = after.range(of: "\u{1B}\\") {
                term = esc.lowerBound
                termLen = 2
            }
            guard let terminatorIndex = term else { break }
            let payload = String(after[..<terminatorIndex])
            let code = payload.first.map(String.init) ?? ""
            let extra = String(payload.dropFirst())
            if let event = handleOSC133(code: code, payload: extra) {
                events.append(event)
                onEvent?(event)
            }
            let nextStart = after.index(terminatorIndex, offsetBy: termLen)
            remaining = String(after[nextStart...])
        }
        return events
    }

    private func handleOSC133(code: String, payload: String) -> ShellEvent? {
        switch code {
        case "A":
            logger.debug("OSC133 A prompt start")
            return .promptStart
        case "B":
            pendingCommand = ""
            return nil
        case "C":
            let cmd = payload.isEmpty ? pendingCommand : payload
            let range = ShellCommandRange(id: UUID(), startLine: lineCounter, endLine: nil, command: cmd, startTime: Date())
            current = range
            // Feed echo tracker for ultimate correlation
            if !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
                PTYEchoTracker.shared.record(cmd)
            }
            return .commandStart(range)
        case "D":
            guard var cur = current else { return nil }
            cur.endLine = lineCounter
            // exit code is after first ';' or bare number
            let exitCode = Int(payload.split(separator: ";").first ?? Substring(payload)) ?? Int(payload)
            commands.append(cur)
            if commands.count > 200 { commands.removeFirst(50) }
            current = nil
            let data: [String: Any] = ["command": cur, "exitCode": exitCode as Any]
            NotificationCenter.default.post(name: .shellCommandDidEnd, object: nil, userInfo: data)
            let event = ShellEvent.commandEnd(cur, exitCode: exitCode)
            return event
        default:
            return nil
        }
    }

    func appendInput(_ text: String) {
        pendingCommand += text
        if pendingCommand.count > 1024 { pendingCommand = String(pendingCommand.suffix(512)) }
    }

    func jump(to direction: Int) {
        // direction: -1 = previous, +1 = next
        guard !commands.isEmpty else { return }
        // Find nearest command relative to current lineCounter
        let sorted = commands.sorted { $0.startLine < $1.startLine }
        var target: ShellCommandRange?
        if direction < 0 {
            target = sorted.last(where: { $0.startLine < lineCounter }) ?? sorted.last
        } else {
            target = sorted.first(where: { $0.startLine > lineCounter }) ?? sorted.first
        }
        if let targetRange = target {
            NotificationCenter.default.post(name: .shellJumpToCommand, object: nil, userInfo: ["line": targetRange.startLine, "id": targetRange.id])
        }
    }
}

extension Notification.Name {
    static let shellCommandDidEnd = Notification.Name("ShellCommandDidEnd")
    static let shellJumpToCommand = Notification.Name("ShellJumpToCommand")
    static let commandBlockDidAdd = Notification.Name("CommandBlockDidAdd")
    static let commandBlocksDidClear = Notification.Name("CommandBlocksDidClear")
}
