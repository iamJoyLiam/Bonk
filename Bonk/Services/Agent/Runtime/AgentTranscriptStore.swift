//
//  AgentTranscriptStore.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation
import os

/// Immutable log storage for all AgentEvents occurring during a session.
/// Enables playback, auditability, and context compaction.
final class AgentTranscriptStore: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[AgentEvent]>(uncheckedState: [])

    init() {}

    func append(_ event: AgentEvent) {
        state.withLock { $0.append(event) }
    }

    var events: [AgentEvent] {
        state.withLock { $0 }
    }

    func clear() {
        state.withLock { $0.removeAll() }
    }

    /// Exports clean transcript text for audit or model compaction.
    func exportTextTranscript() -> String {
        let currentEvents = events
        var lines: [String] = []

        for event in currentEvents {
            switch event {
            case let .userMessage(msg):
                lines.append("[User]: \(msg)")
            case let .assistantText(msg):
                lines.append("[Assistant]: \(msg)")
            case let .thinking(thought):
                lines.append("[Thinking]: \(thought)")
            case let .toolCallStarted(id, tool, input):
                lines.append("[ToolCall \(id)]: \(tool) -> \(input)")
            case let .toolOutput(id, output):
                lines.append("[ToolOutput \(id)]: \(output)")
            case let .toolCompleted(id, exitCode, duration):
                lines.append("[ToolCompleted \(id)]: code=\(exitCode) duration=\(String(format: "%.2fs", duration))")
            case let .permissionRequested(id, desc, level):
                lines.append("[Permission \(id)]: \(level) -> \(desc)")
            case let .permissionResolved(id, approved):
                lines.append("[PermissionResolved \(id)]: approved=\(approved)")
            case let .executionInterrupted(reason):
                lines.append("[Interrupted]: \(reason)")
            case let .error(err):
                lines.append("[Error]: \(err)")
            case .completed:
                lines.append("[Completed]")
            }
        }

        return lines.joined(separator: "\n")
    }
}
