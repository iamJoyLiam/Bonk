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

/// Machine-readable error classification. Visual rendering stays uniform
/// for now (Tier B); the type exists so future UI and audit never rely
/// on message-text matching.
enum AgentErrorCode: String, Sendable, Equatable {
    /// Semantic progress stalled (Phase 3 evaluator break).
    case progressStall
    /// Budget cap hit (Phase 5 enforcement halt).
    case budgetExceeded
    /// Model call failed (transport, auth, invalid response).
    case modelFailure
    /// Anything else (policy blocks, guard terminations, loop brakes).
    case generic
}

/// Immutable, unified event stream emitted by AgentRuntime.
/// SwiftUI views consume this stream reactively rather than directly driving tool executions.
///
/// Vocabulary discipline (UI must mirror it):
/// - PermissionDecision (allowed/confirmRequired/blocked) = security verdict.
/// - FoldDecision (fold/keep) = confirmation-experience decision.
/// A folded confirmation is NEVER an allowed verdict: `permissionFolded`
/// records that an existing .confirmRequired dialog was folded, with the
/// deterministic facts (level, history) and the deciding engine attached.
enum AgentEvent: Sendable, Equatable {
    case userMessage(String)
    case assistantText(String)
    /// A piece of the assistant's answer, as it arrives.
    ///
    /// Presentation only: the transcript coalesces the pieces back into one
    /// assistant turn, and the complete text is what the model history
    /// records. A consumer that appends the pieces sees the answer being
    /// written.
    case assistantTextDelta(String)
    case thinking(String)
    case toolCallStarted(id: String, tool: String, input: String)
    case toolOutput(id: String, output: String)
    case toolCompleted(id: String, exitCode: Int32, duration: TimeInterval)
    case permissionRequested(id: String, description: String, level: PermissionLevel, reason: String)
    case permissionResolved(id: String, approved: Bool)
    /// A .confirmRequired dialog folded by the fold gate. `level` is the
    /// deterministic safety label (e.g. "L2"), `engine` the deciding engine.
    /// The command still executed under a confirmRequired verdict.
    case permissionFolded(id: String, command: String, level: String, engine: String)
    case executionInterrupted(reason: String)
    case error(code: AgentErrorCode, message: String)
    /// History was compacted. UI-only: mapping layers render it as a
    /// transcript note; it never enters LLM conversation messages.
    case contextCompacted
    case completed
}
