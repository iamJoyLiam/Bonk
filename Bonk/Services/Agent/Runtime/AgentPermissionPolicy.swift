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

    init(accessMode: AgentMessage.AccessMode = .supervised) {
        self.accessMode = accessMode
    }

    func evaluate(tool: String, arguments: [String: String]) -> PermissionDecision {
        // Safe read-only tool definitions like inspect_history, read_file, inspect_system, or list_dir
        if tool == "read_file" || tool == "search_history" || tool == "inspect_system" || tool == "list_dir" {
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
                return .confirmRequired(level: .confirmRequired, description: "Mutating command requires approval: \(cmd)")
            case .fullAccess:
                return .allowed
            }

        case .l3HighRisk:
            switch accessMode {
            case .readOnly:
                return .blocked(reason: "Read-only mode blocks high-risk command: \(cmd)")
            case .supervised, .fullAccess:
                return .confirmRequired(level: .confirmRequired, description: "High-risk command requires explicit confirmation: \(cmd)")
            }

        case .l4Critical:
            return .blocked(reason: "Critical command blocked by security policy: \(cmd)")
        }
    }
}
