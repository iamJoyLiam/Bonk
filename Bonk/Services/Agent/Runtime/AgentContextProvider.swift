//
//  AgentContextProvider.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation

/// The environment the agent runs in, split by provenance.
///
/// The split is structural, not a convention. `system` is the role that
/// carries authority, so a remote byte placed there speaks in the product's
/// voice — that is the vulnerability, not a formatting detail. Handing
/// callers one finished string and asking them not to append remote bytes
/// to it is exactly the arrangement that produced the defect: the Ask path
/// had to learn this the hard way, and the agent path was left with the
/// same shape.
///
/// So the two halves are separate fields. Putting remote state in the
/// authority role now takes rebuilding the string by hand, which is visible
/// in a diff.
struct AgentContext: Sendable {
    /// App-authored facts. Safe in the authority role: the connected host's
    /// display name is the user's own label for the machine.
    let trusted: String
    /// Remote-derived facts. Renders as an untrusted block for a user-role
    /// message — never as part of the system prompt.
    let remote: RemoteTerminalState?
}

/// Protocol for collecting environmental state into the Agent's prompt context.
protocol AgentContextProvider: Sendable {
    func assembleContext(input: String) async -> AgentContext
}

/// Default implementation collecting terminal screen, working directory, host info,
/// command history, selected text, and git repository state.
///
/// The host's display name is the user's own label, so it is trusted. Every
/// other field here came from the remote host — the scrollback, the working
/// directory, the command history, the selection, the git status — and is
/// carried as `RemoteTerminalState` so that it can only be rendered as
/// untrusted data.
struct DefaultAgentContextProvider: AgentContextProvider {
    let hostInfo: String?
    private let remote: RemoteTerminalState

    init(
        terminalScreen: String? = nil,
        workingDirectory: String? = nil,
        hostInfo: String? = nil,
        commandHistory: [String] = [],
        selectedText: String? = nil,
        gitStatus: String? = nil
    ) {
        self.hostInfo = hostInfo
        self.remote = RemoteTerminalState(
            currentDirectory: workingDirectory,
            recentCommands: commandHistory,
            recentOutput: terminalScreen,
            selection: selectedText,
            gitStatus: gitStatus
        )
    }

    func assembleContext(input: String) async -> AgentContext {
        var trusted: [String] = []
        if let hostInfo, !hostInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trusted.append(
                "### Connected Host\n\(hostInfo.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return AgentContext(
            trusted: trusted.joined(separator: "\n\n"),
            remote: remote.isEmpty ? nil : remote
        )
    }
}
