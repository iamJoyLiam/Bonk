//  CommandNormalizer.swift
//  Bonk
//
//  Phase 1 deterministic fact extractors for agent decisions. These produce
//  FACTS (normalized key, semantic tags) — never verdicts. They sit above
//  CommandSafety (which owns risk levels) and below DecisionContext (which
//  consumes their output). Pure, synchronous, no I/O: safe anywhere.

import Foundation

/// Deterministic command normalization: same operation, different paths or
/// spacing, must produce the same key so decision memory can recognize
/// "the user already approved this kind of operation".
enum CommandNormalizer {
    static let maxKeyLength = 256

    static func normalizedKey(_ command: String) -> String {
        var key = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse all whitespace runs (spaces, tabs, newlines) to one space.
        key = key.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // Home directory variants collapse to <home>.
        let home = NSHomeDirectory()
        if !home.isEmpty {
            key = key.replacingOccurrences(of: home, with: "<home>")
        }
        key = key.replacingOccurrences(of: "^~(?=/|$)", with: "<home>", options: .regularExpression)
        if key.count > maxKeyLength {
            key = String(key.prefix(maxKeyLength))
        }
        return key
    }
}

/// Coarse, stable semantic categories for one command. First version is
/// deliberately small: every tag must be explainable from the argv verb
/// plus operators, with no model and no network.
enum SemanticTag: String, Sendable, CaseIterable {
    case filesystemRead
    case filesystemWrite
    case filesystemDelete
    case processExecute
    case processSignal
    case privilegeEscalation
    case packageInstall
    case networkAccess
    case gitRead
    case gitMutate
}

enum SemanticTagger {
    /// Tags eligible for Phase-2 confirmation folding on their own merit.
    /// Conservative: read-only categories only. Phase 2 additionally requires
    /// L0/L1 safety level plus explicit prior approval.
    static let lowRiskTags: Set<SemanticTag> = [.filesystemRead, .gitRead]

    private static let chainOperators = ["&&", "||", ";", "|"]

    static func tag(command: String) -> Set<SemanticTag> {
        var tags = Set<SemanticTag>()
        for segment in splitSegments(command) {
            tagSegment(segment, into: &tags)
        }
        if tags.isEmpty {
            tags.insert(.processExecute)
        }
        return tags
    }

    // MARK: - Segmentation

    private static func splitSegments(_ command: String) -> [String] {
        var segments = [command]
        for op in chainOperators {
            segments = segments.flatMap { $0.components(separatedBy: op) }
        }
        return segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Per-segment tagging

    private static func tagSegment(_ segment: String, into tags: inout Set<SemanticTag>) {
        // Redirects imply a write even when the verb alone looks innocent.
        if segment.contains(">") {
            tags.insert(.filesystemWrite)
        }
        var words = segment.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        // sudo elevates everything after it; tag both the escalation and the rest.
        if words[0] == "sudo" {
            tags.insert(.privilegeEscalation)
            words.removeFirst()
            guard !words.isEmpty else { return }
        }
        let verb = words[0]
        let args = Array(words.dropFirst())
        switch verb {
        case "ls", "cat", "head", "tail", "less", "more", "file", "stat",
             "df", "du", "ps", "pwd", "whoami", "uname", "uptime", "vm_stat",
             "which", "whereis", "find", "grep", "wc", "diff", "tree":
            tags.insert(.filesystemRead)
        case "mkdir", "touch", "cp", "mv", "ln", "chmod", "chown", "tee", "truncate":
            tags.insert(.filesystemWrite)
        case "rm", "rmdir", "shred":
            tags.insert(.filesystemDelete)
        case "kill", "killall", "pkill", "reboot", "shutdown", "halt", "poweroff":
            tags.insert(.processSignal)
        case "curl", "wget", "ssh", "scp", "sftp", "ftp", "nc", "telnet", "ping":
            tags.insert(.networkAccess)
        case "git":
            tags.insert(args.first.map(gitMutatingVerbs.contains) == true ? .gitMutate : .gitRead)
        case "brew", "apt", "apt-get", "yum", "dnf", "apk", "npm", "yarn", "pnpm", "pip", "pip3", "gem", "cargo":
            if args.contains(where: packageMutatingVerbs.contains) {
                tags.insert(.packageInstall)
            } else {
                tags.insert(.processExecute)
            }
        case "docker":
            tagDocker(args: args, into: &tags)
        default:
            tags.insert(.processExecute)
        }
    }

    private static let gitMutatingVerbs: Set<String> = [
        "add", "commit", "push", "pull", "merge", "rebase", "reset", "clean",
        "checkout", "switch", "restore", "rm", "mv", "clone", "stash", "apply",
    ]

    private static let packageMutatingVerbs: Set<String> = [
        "install", "uninstall", "remove", "upgrade", "update",
    ]

    private static func tagDocker(args: [String], into tags: inout Set<SemanticTag>) {
        guard let sub = args.first else {
            tags.insert(.processExecute)
            return
        }
        switch sub {
        case "ps", "images", "inspect", "logs", "stats", "version", "info":
            tags.insert(.filesystemRead)
        case "rm", "rmi", "kill", "prune":
            tags.insert(.filesystemDelete)
        case "stop", "restart", "start", "pause", "unpause":
            tags.insert(.processSignal)
        default:
            tags.insert(.processExecute)
        }
    }
}
