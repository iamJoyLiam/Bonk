//
//  AgentEvent.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation

/// Permission level required to execute a tool action.
enum PermissionLevel: String, Sendable, Codable, Equatable {
    case safe
    case confirmRequired
    case blocked
}

/// Immutable, unified event stream emitted by AgentRuntime.
/// SwiftUI views consume this stream reactively rather than directly driving tool executions.
enum AgentEvent: Sendable, Equatable {
    case userMessage(String)
    case assistantText(String)
    case thinking(String)
    case toolCallStarted(id: String, tool: String, input: String)
    case toolOutput(id: String, output: String)
    case toolCompleted(id: String, exitCode: Int32, duration: TimeInterval)
    case permissionRequested(id: String, description: String, level: PermissionLevel)
    case permissionResolved(id: String, approved: Bool)
    case executionInterrupted(reason: String)
    case error(String)
    case completed
}
