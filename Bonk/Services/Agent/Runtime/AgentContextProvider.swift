//
//  AgentContextProvider.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation

/// Protocol for collecting environmental state into the Agent's prompt context.
protocol AgentContextProvider: Sendable {
    func assembleContext(input: String) async -> String
}

/// Default implementation collecting terminal screen, working directory, host info,
/// command history, selected text, and git repository state.
struct DefaultAgentContextProvider: AgentContextProvider {
    let terminalScreen: String?
    let workingDirectory: String?
    let hostInfo: String?
    let commandHistory: [String]
    let selectedText: String?
    let gitStatus: String?

    init(
        terminalScreen: String? = nil,
        workingDirectory: String? = nil,
        hostInfo: String? = nil,
        commandHistory: [String] = [],
        selectedText: String? = nil,
        gitStatus: String? = nil
    ) {
        self.terminalScreen = terminalScreen
        self.workingDirectory = workingDirectory
        self.hostInfo = hostInfo
        self.commandHistory = commandHistory
        self.selectedText = selectedText
        self.gitStatus = gitStatus
    }

    func assembleContext(input: String) async -> String {
        var sections: [String] = []

        if let hostInfo, !hostInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("### Connected Host\n\(hostInfo.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if let workingDirectory, !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("### Current Working Directory\n\(workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if let gitStatus, !gitStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("### Git Repository Status\n\(gitStatus.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("### Selected Text\n```\n\(selectedText)\n```")
        }

        if !commandHistory.isEmpty {
            let recent = commandHistory.suffix(10).joined(separator: "\n")
            sections.append("### Recent Terminal History\n```bash\n\(recent)\n```")
        }

        if let terminalScreen, !terminalScreen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let guarded = OutputGuard.guardOutput(terminalScreen).content
            sections.append("### Active Terminal Screen\n```\n\(guarded)\n```")
        }

        return sections.joined(separator: "\n\n")
    }
}
