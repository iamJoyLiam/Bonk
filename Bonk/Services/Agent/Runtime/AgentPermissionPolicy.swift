//
//  AgentPermissionPolicy.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation

/// Decision outcome for tool execution permission.
enum PermissionDecision: Sendable, Equatable {
    case allowed
    case confirmRequired(level: PermissionLevel, description: String)
    case blocked(reason: String)
}

/// Policy rule interface deciding if a tool call can proceed, requires approval, or is blocked.
protocol AgentPermissionPolicy: Sendable {
    func evaluate(tool: String, arguments: [String: String]) -> PermissionDecision
}

/// Default rule-based permission gate.
/// Evaluates commands against `CommandSafety` levels (L0..L4) and user access modes:
/// - Read-Only: blocks any state-mutating (L2) or dangerous (L3/L4) commands.
/// - Supervised: L1 runs automatically, L2 & L3 require explicit confirmation, L4 is blocked.
/// - Full Access (Autonomous): L1 & L2 run automatically, L3 requires confirmation, L4 is blocked.
struct DefaultAgentPermissionPolicy: AgentPermissionPolicy {
    let accessMode: AgentMessage.AccessMode
    /// The host this run is authorized against.
    ///
    /// The host's stable identifier, never its display name. nil means the
    /// run has no host, and then no standing authorization can apply — a
    /// rule that is not scoped to a host covers nothing.
    let hostScope: String?
    /// The standing authorizations.
    let allowlist: AgentAllowlist

    init(
        accessMode: AgentMessage.AccessMode = .supervised,
        hostScope: String? = nil,
        allowlist: AgentAllowlist = .shared
    ) {
        self.accessMode = accessMode
        self.hostScope = hostScope
        self.allowlist = allowlist
    }

    /// Does the user already have a standing authorization for this command
    /// on this host?
    private func isStandinglyAllowed(_ command: String) -> Bool {
        guard let hostScope, !hostScope.isEmpty else { return false }
        return allowlist.covers(command: command, hostScope: hostScope)
    }

    func evaluate(tool: String, arguments: [String: String]) -> PermissionDecision {
        // Safe read-only tool definitions like inspect_history, read_file, inspect_system, or list_dir
        if tool == "read_file" || tool == "search_history" || tool == "inspect_system" || tool == "list_dir" {
            return .allowed
        }
        // The task list runs nothing. It writes the model's own checklist to
        // this run's memory and returns it; it never touches the target
        // system, so there is nothing to confirm.
        if tool == TodoWriteTool.toolName {
            return .allowed
        }
        // The skill tool reads one file from a fixed location on the host:
        // the user's own skills directory, under a name the tool validates
        // before it reaches a path. It is a read of the same kind as
        // `read_file` — narrower, in fact, because the path is not the
        // model's to choose.
        if tool == SkillTool.toolName {
            return .allowed
        }
        // The sub-agent tool starts a nested run. It runs nothing on the
        // host itself: the commands the sub-agent issues are judged by this
        // same policy one level down, where a sub-agent cannot ask the user
        // and a command needing approval is refused. So the tool call
        // itself is allowed, and what it leads to is not.
        if tool == SubAgentTool.toolName {
            return .allowed
        }

        guard tool == "run_command" || tool == "bash_run" else {
            // Unknown or generic tools default to confirm
            return .confirmRequired(level: .confirmRequired, description: "Unknown tool call: \(tool)")
        }

        guard let cmd = arguments["command"]?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty else {
            return .blocked(reason: "Empty command string.")
        }

        let level = CommandSafety.classifyLevel(cmd)
        switch level {
        case .l0Explanation, .l1SafeInspection:
            return .allowed

        case .l2StateMutation:
            switch accessMode {
            case .readOnly:
                return .blocked(reason: "Read-only mode blocks command modifying state: \(cmd)")
            case .supervised:
                // A standing authorization turns the question into an
                // answer. It does not touch a refusal: read-only mode is
                // still read-only.
                if isStandinglyAllowed(cmd) {
                    return .allowed
                }
                return .confirmRequired(level: .confirmRequired, description: "Mutating command requires approval: \(cmd)")
            case .fullAccess:
                return .allowed
            }

        case .l3HighRisk:
            switch accessMode {
            case .readOnly:
                return .blocked(reason: "Read-only mode blocks high-risk command: \(cmd)")
            case .supervised, .fullAccess:
                if isStandinglyAllowed(cmd) {
                    return .allowed
                }
                return .confirmRequired(level: .confirmRequired, description: "High-risk command requires explicit confirmation: \(cmd)")
            }

        case .l4Critical:
            return .blocked(reason: "Critical command blocked by security policy: \(cmd)")
        }
    }
}
