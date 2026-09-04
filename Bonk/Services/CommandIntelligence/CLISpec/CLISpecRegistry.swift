//
//  CLISpecRegistry.swift
//  Bonk
//
//  Registry of CLI specifications providing deterministic candidate generation.
//  P1 Hard Gate: ensures valid subcommands and flags appear instantly without LLM hallucination.
//

import Foundation
import os

/// Registry that stores and queries CLI command specifications.
final class CLISpecRegistry: @unchecked Sendable {
    static let shared = CLISpecRegistry()

    private let specs: OSAllocatedUnfairLock<[String: CLISpec]>

    init(specs: [CLISpec] = CLISpecRegistry.defaultSpecs) {
        var map: [String: CLISpec] = [:]
        for spec in specs {
            map[spec.command.lowercased()] = spec
        }
        self.specs = OSAllocatedUnfairLock(initialState: map)
    }

    /// Register or extend a CLI specification.
    func register(_ spec: CLISpec) {
        specs.withLock { dict in
            dict[spec.command.lowercased()] = spec
        }
    }

    /// Retrieve specification for a root command name.
    func spec(for command: String) -> CLISpec? {
        specs.withLock { $0[command.lowercased()] }
    }

    /// Generate deterministic candidates from CLI specs for typed buffer.
    func candidates(for typed: String) -> [CommandCandidate] {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Tokenize typed line preserving trailing whitespace
        let tokens = typed.split(separator: " ", omittingEmptySubsequences: false)
        guard let firstToken = tokens.first, !firstToken.isEmpty else { return [] }
        let rootCommand = String(firstToken).lowercased()

        guard let cliSpec = spec(for: rootCommand) else { return [] }

        let endsWithSpace = typed.hasSuffix(" ")

        // Case 1: Just root command typed: "docker" or "docker "
        if tokens.count == 1 && !endsWithSpace {
            // "docker" -> no subcommand query yet, user is at end of root token
            return []
        }

        // Case 2: Root command followed by space or partial subcommand
        // e.g. "docker " (tokens=["docker", ""]), "docker ps" (tokens=["docker", "ps"])
        if tokens.count == 2 || (tokens.count == 1 && endsWithSpace) {
            let subQuery = tokens.count > 1 ? String(tokens[1]) : ""
            let matching = cliSpec.matchSubcommands(query: subQuery)

            return matching.map { sub -> CommandCandidate in
                let fullCommand = "\(cliSpec.command) \(sub.name)"
                let suffix: String
                if endsWithSpace {
                    // e.g. typed is "docker ", user wants "ps"
                    suffix = sub.name
                } else {
                    // e.g. typed is "docker p", user wants "s"
                    let typedSub = subQuery
                    suffix = sub.name.hasPrefix(typedSub) ? String(sub.name.dropFirst(typedSub.count)) : sub.name
                }

                let display = sub.summary.isEmpty ? suffix : "\(suffix) (\(sub.summary))"
                let sug = Suggestion(
                    text: suffix,
                    displayText: display,
                    fullText: fullCommand
                )

                let isExact = sub.name.lowercased() == subQuery.lowercased()
                let rawScore = sub.priority + (isExact ? 20.0 : 0.0)

                return CommandCandidate(
                    source: "cliSpec",
                    authority: .deterministic,
                    suggestion: sug,
                    rawScore: rawScore,
                    isExactPrefixMatch: isExact
                )
            }
        }

        // Case 3: Subcommand already typed, looking for sub-subcommands or common flags
        // e.g. "docker compose " or "docker ps -"
        if tokens.count >= 2 {
            let subName = String(tokens[1]).lowercased()
            if let matchedSub = cliSpec.subcommands.first(where: { $0.name.lowercased() == subName }) {
                let lastToken = tokens.last.map(String.init) ?? ""
                var candidates: [CommandCandidate] = []

                for flag in matchedSub.commonFlags {
                    let fullCommand: String
                    let suffix: String

                    if endsWithSpace {
                        fullCommand = "\(typed)\(flag)"
                        suffix = flag
                    } else if flag.hasPrefix(lastToken) {
                        let remaining = String(flag.dropFirst(lastToken.count))
                        fullCommand = "\(typed)\(remaining)"
                        suffix = remaining
                    } else {
                        continue
                    }

                    let sug = Suggestion(
                        text: suffix,
                        displayText: suffix,
                        fullText: fullCommand
                    )
                    candidates.append(CommandCandidate(
                        source: "cliSpecFlag",
                        authority: .deterministic,
                        suggestion: sug,
                        rawScore: 85.0,
                        isExactPrefixMatch: flag == lastToken
                    ))
                }
                if !candidates.isEmpty {
                    return candidates
                }
            }
        }

        return []
    }

    /// Curated built-in specs for major developer CLI tools.
    static let defaultSpecs: [CLISpec] = [
        CLISpec(
            command: "docker",
            summary: "Container runtime and management",
            subcommands: [
                CLISubcommand(name: "ps", summary: "List containers", commonFlags: ["-a", "-q"], priority: 95.0),
                CLISubcommand(name: "images", summary: "List images", commonFlags: ["-a"], priority: 92.0),
                CLISubcommand(name: "run", summary: "Run a container", commonFlags: ["-d", "-it", "-p", "-v", "--rm"], priority: 90.0),
                CLISubcommand(name: "compose", summary: "Docker Compose", commonFlags: ["up -d", "down", "ps", "logs -f", "build", "restart"], priority: 88.0),
                CLISubcommand(name: "logs", summary: "Fetch container logs", commonFlags: ["-f", "--tail 100"], priority: 85.0),
                CLISubcommand(name: "exec", summary: "Run command in container", commonFlags: ["-it"], priority: 84.0),
                CLISubcommand(name: "build", summary: "Build an image from Dockerfile", commonFlags: ["-t", "."], priority: 82.0),
                CLISubcommand(name: "stop", summary: "Stop containers", priority: 80.0),
                CLISubcommand(name: "start", summary: "Start stopped containers", priority: 78.0),
                CLISubcommand(name: "restart", summary: "Restart containers", priority: 77.0),
                CLISubcommand(name: "pull", summary: "Download an image", priority: 76.0),
                CLISubcommand(name: "push", summary: "Upload an image", priority: 75.0),
                CLISubcommand(name: "rm", summary: "Remove containers", commonFlags: ["-f"], priority: 72.0),
                CLISubcommand(name: "rmi", summary: "Remove images", commonFlags: ["-f"], priority: 70.0),
                CLISubcommand(name: "stats", summary: "Display live resource usage", priority: 68.0),
                CLISubcommand(name: "inspect", summary: "Inspect Docker objects", priority: 65.0),
                CLISubcommand(name: "network", summary: "Manage networks", commonFlags: ["ls", "create", "rm"], priority: 60.0),
                CLISubcommand(name: "volume", summary: "Manage volumes", commonFlags: ["ls", "create", "rm"], priority: 60.0),
                CLISubcommand(name: "system", summary: "Manage Docker system", commonFlags: ["prune -a", "df"], priority: 55.0),
            ]
        ),
        CLISpec(
            command: "git",
            summary: "Distributed version control system",
            subcommands: [
                CLISubcommand(name: "status", summary: "Show working tree status", commonFlags: ["-s", "-b"], priority: 98.0),
                CLISubcommand(name: "log", summary: "Show commit logs", commonFlags: ["--oneline -n 10", "-p"], priority: 94.0),
                CLISubcommand(name: "diff", summary: "Show changes between commits/worktree", commonFlags: ["--staged", "HEAD"], priority: 92.0),
                CLISubcommand(name: "add", summary: "Add file contents to index", commonFlags: [".", "-A", "-p"], priority: 90.0),
                CLISubcommand(name: "commit", summary: "Record changes to repo", commonFlags: ["-m", "-am", "--amend"], priority: 89.0),
                CLISubcommand(name: "push", summary: "Update remote refs", commonFlags: ["origin", "-u origin main"], priority: 88.0),
                CLISubcommand(name: "pull", summary: "Fetch and integrate from remote", commonFlags: ["--rebase", "origin main"], priority: 87.0),
                CLISubcommand(name: "checkout", summary: "Switch branches or restore files", commonFlags: ["-b"], priority: 85.0),
                CLISubcommand(name: "switch", summary: "Switch branches", commonFlags: ["-c"], priority: 84.0),
                CLISubcommand(name: "branch", summary: "List or delete branches", commonFlags: ["-a", "-d"], priority: 82.0),
                CLISubcommand(name: "merge", summary: "Join development histories", priority: 80.0),
                CLISubcommand(name: "rebase", summary: "Reapply commits on another base", commonFlags: ["-i", "--continue", "--abort"], priority: 78.0),
                CLISubcommand(name: "stash", summary: "Stash changes in dirty worktree", commonFlags: ["pop", "list", "drop"], priority: 76.0),
                CLISubcommand(name: "fetch", summary: "Download objects from remote", commonFlags: ["--all", "--prune"], priority: 74.0),
                CLISubcommand(name: "clone", summary: "Clone repository into new directory", priority: 72.0),
                CLISubcommand(name: "reset", summary: "Reset current HEAD", commonFlags: ["--hard", "--soft HEAD~1"], priority: 70.0),
                CLISubcommand(name: "restore", summary: "Restore working tree files", commonFlags: ["--staged"], priority: 68.0),
                CLISubcommand(name: "cherry-pick", summary: "Apply changes of existing commits", priority: 65.0),
                CLISubcommand(name: "tag", summary: "Create or list tags", commonFlags: ["-a", "-l"], priority: 60.0),
                CLISubcommand(name: "remote", summary: "Manage tracked remotes", commonFlags: ["-v", "add", "remove"], priority: 60.0),
            ]
        ),
        CLISpec(
            command: "kubectl",
            summary: "Kubernetes cluster control",
            subcommands: [
                CLISubcommand(name: "get", summary: "Display resources", commonFlags: ["pods -A", "services", "deployments", "nodes", "-o wide"], priority: 95.0),
                CLISubcommand(name: "describe", summary: "Show details of resources", commonFlags: ["pod", "node", "deployment"], priority: 90.0),
                CLISubcommand(name: "logs", summary: "Print container logs", commonFlags: ["-f", "--tail 100"], priority: 88.0),
                CLISubcommand(name: "exec", summary: "Execute command in pod", commonFlags: ["-it -- /bin/sh", "-it -- /bin/bash"], priority: 86.0),
                CLISubcommand(name: "apply", summary: "Apply resource configuration", commonFlags: ["-f"], priority: 84.0),
                CLISubcommand(name: "delete", summary: "Delete resources", commonFlags: ["pod", "-f"], priority: 80.0),
                CLISubcommand(name: "top", summary: "Display CPU/memory usage", commonFlags: ["pods", "nodes"], priority: 78.0),
                CLISubcommand(name: "port-forward", summary: "Forward local port to pod", priority: 76.0),
                CLISubcommand(name: "rollout", summary: "Manage resource rollout", commonFlags: ["status", "restart", "history"], priority: 72.0),
            ]
        ),
        CLISpec(
            command: "npm",
            summary: "Node package manager",
            subcommands: [
                CLISubcommand(name: "run", summary: "Run package script", commonFlags: ["dev", "build", "test", "lint", "start"], priority: 95.0),
                CLISubcommand(name: "install", summary: "Install dependencies", commonFlags: ["--save-dev"], priority: 92.0),
                CLISubcommand(name: "test", summary: "Run test suite", priority: 88.0),
                CLISubcommand(name: "build", summary: "Run build script", priority: 86.0),
                CLISubcommand(name: "start", summary: "Start application", priority: 84.0),
                CLISubcommand(name: "uninstall", summary: "Remove package", priority: 80.0),
                CLISubcommand(name: "update", summary: "Update packages", priority: 75.0),
            ]
        ),
        CLISpec(
            command: "pnpm",
            summary: "Fast, disk space efficient package manager",
            subcommands: [
                CLISubcommand(name: "run", summary: "Run package script", commonFlags: ["dev", "build", "test", "lint"], priority: 95.0),
                CLISubcommand(name: "install", summary: "Install dependencies", priority: 92.0),
                CLISubcommand(name: "add", summary: "Add package", commonFlags: ["-D"], priority: 90.0),
                CLISubcommand(name: "test", summary: "Run test suite", priority: 88.0),
                CLISubcommand(name: "build", summary: "Run build script", priority: 86.0),
                CLISubcommand(name: "remove", summary: "Remove package", priority: 80.0),
            ]
        ),
        CLISpec(
            command: "cargo",
            summary: "Rust package manager and build tool",
            subcommands: [
                CLISubcommand(name: "build", summary: "Compile local packages", commonFlags: ["--release"], priority: 95.0),
                CLISubcommand(name: "run", summary: "Run binary of package", commonFlags: ["--release"], priority: 92.0),
                CLISubcommand(name: "check", summary: "Check code without code gen", priority: 90.0),
                CLISubcommand(name: "test", summary: "Execute tests", priority: 88.0),
                CLISubcommand(name: "clippy", summary: "Run linter checks", priority: 85.0),
                CLISubcommand(name: "fmt", summary: "Format code with rustfmt", commonFlags: ["--check"], priority: 82.0),
                CLISubcommand(name: "add", summary: "Add dependency to Cargo.toml", priority: 80.0),
            ]
        ),
        CLISpec(
            command: "systemctl",
            summary: "Control systemd system and service manager",
            subcommands: [
                CLISubcommand(name: "status", summary: "Show service status", priority: 95.0),
                CLISubcommand(name: "restart", summary: "Restart units", priority: 90.0),
                CLISubcommand(name: "start", summary: "Start units", priority: 85.0),
                CLISubcommand(name: "stop", summary: "Stop units", priority: 82.0),
                CLISubcommand(name: "enable", summary: "Enable unit files", commonFlags: ["--now"], priority: 80.0),
                CLISubcommand(name: "disable", summary: "Disable unit files", commonFlags: ["--now"], priority: 78.0),
                CLISubcommand(name: "reload", summary: "Reload unit configuration", priority: 75.0),
            ]
        ),
        CLISpec(
            command: "brew",
            summary: "macOS package manager",
            subcommands: [
                CLISubcommand(name: "install", summary: "Install formula or cask", priority: 95.0),
                CLISubcommand(name: "update", summary: "Fetch newest Homebrew", priority: 92.0),
                CLISubcommand(name: "upgrade", summary: "Upgrade outdated packages", priority: 90.0),
                CLISubcommand(name: "list", summary: "List installed packages", priority: 88.0),
                CLISubcommand(name: "search", summary: "Search for packages", priority: 85.0),
                CLISubcommand(name: "info", summary: "Display package info", priority: 82.0),
                CLISubcommand(name: "services", summary: "Manage background services", commonFlags: ["list", "start", "stop", "restart"], priority: 80.0),
                CLISubcommand(name: "cleanup", summary: "Remove stale files", priority: 75.0),
            ]
        )
    ]
}
