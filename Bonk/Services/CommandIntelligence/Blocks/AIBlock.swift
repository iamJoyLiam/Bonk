//  AIBlock.swift
//  Bonk — AIMessage → Block (Invariant #9): Capability-based rendering
//  Command/Code/Table/Tool/Diff/Text → MDBlockRenderer

import Foundation

enum AIBlock: Sendable, Equatable, Identifiable {
    case text(String)
    case code(String, language: String?)
    case command(String) // Runnable
    case table([[String]]) // first row header
    case tool(name: String, input: String, output: String)
    case diff(String) // unified diff

    var id: String {
        switch self {
        case .text(let s): "text:\(s.hashValue)"
        case .code(let s, _): "code:\(s.hashValue)"
        case .command(let s): "cmd:\(s.hashValue)"
        case .table(let rows): "table:\(rows.count)"
        case .tool(let n, _, _): "tool:\(n)"
        case .diff(let s): "diff:\(s.hashValue)"
        }
    }

    var isRunnable: Bool {
        if case .command = self { return true }
        return false
    }
    var isCopyable: Bool { true }
}

struct AIMessage: Sendable, Equatable, Identifiable {
    let id: UUID
    let role: Role
    let blocks: [AIBlock]
    let timestamp: Date
    enum Role: Sendable { case user, assistant, tool }
    init(id: UUID = UUID(), role: Role, blocks: [AIBlock], timestamp: Date = Date()) {
        self.id = id; self.role = role; self.blocks = blocks; self.timestamp = timestamp
    }
    static func from(text: String, role: Role = .assistant) -> AIMessage {
        // Simple parser: ```code``` → code block, `cmd:` → command, else text
        var blocks: [AIBlock] = []
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                let lines = part.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = lines.dropFirst().joined(separator: "\n")
                blocks.append(.code(code, language: lang?.isEmpty == true ? nil : lang))
            } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Detect command lines starting with $ or >
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("$ ") {
                    blocks.append(.command(String(trimmed.dropFirst(2))))
                } else {
                    blocks.append(.text(part))
                }
            }
        }
        if blocks.isEmpty { blocks = [.text(text)] }
        return AIMessage(role: role, blocks: blocks)
    }
}
