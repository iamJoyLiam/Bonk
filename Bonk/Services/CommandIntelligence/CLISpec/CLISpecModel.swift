//
//  CLISpecModel.swift
//  Bonk
//
//  Structured model for CLI commands, subcommands, and flags.
//  Acts as the deterministic Hard Gate for inline command completion.
//

import Foundation

/// A CLI subcommand or action (e.g. `docker ps`, `git commit`).
struct CLISubcommand: Sendable, Hashable {
    let name: String
    let summary: String
    let commonFlags: [String]
    let priority: Double

    init(name: String, summary: String = "", commonFlags: [String] = [], priority: Double = 80.0) {
        self.name = name
        self.summary = summary
        self.commonFlags = commonFlags
        self.priority = priority
    }
}

/// Specification for a root CLI command (e.g. `docker`, `git`, `kubectl`).
struct CLISpec: Sendable {
    let command: String
    let summary: String
    let subcommands: [CLISubcommand]
    let globalFlags: [String]

    init(command: String, summary: String = "", subcommands: [CLISubcommand] = [], globalFlags: [String] = []) {
        self.command = command
        self.summary = summary
        self.subcommands = subcommands
        self.globalFlags = globalFlags
    }

    /// Match subcommands and flags against a typed subcommand query.
    func matchSubcommands(query: String) -> [CLISubcommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            return subcommands.sorted(by: { $0.priority > $1.priority })
        }
        return subcommands
            .filter { $0.name.lowercased().hasPrefix(q) }
            .sorted(by: { (a, b) -> Bool in
                // Exact match first, then prefix, then higher priority
                if a.name == q { return true }
                if b.name == q { return false }
                return a.priority > b.priority
            })
    }
}
