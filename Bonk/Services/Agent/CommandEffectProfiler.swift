//  CommandEffectProfiler.swift
//  Bonk
//
//  Deterministic command-effect analysis for confirmation folding.
//  Answers one question: "does this command have foldable effects?"
//  (local, reversible, non-destructive, no escalation, no network or
//  package side effects, no signals, known semantics).
//
//  This is deliberately separate from CommandSafety (risk levels) and
//  SemanticTagger (categories): effect is about foldability, not risk.
//  Pure, synchronous, no I/O.

import Foundation

/// Foldability verdict for one command. `foldable` is a hard AND over
/// the exclusion rules — unknown semantics never fold.
struct CommandEffectProfile: Sendable, Equatable {
    let tags: Set<SemanticTag>
    /// False when any chain segment starts with a verb the tagger does
    /// not explicitly model. Unknown verbs never fold, even if the
    /// level and history would otherwise allow it.
    let knownVerb: Bool

    var foldable: Bool {
        guard knownVerb else { return false }
        let forbidden: Set<SemanticTag> = [
            .filesystemDelete,
            .privilegeEscalation,
            .processSignal,
            .packageInstall,
            .networkAccess,
            .gitMutate,
        ]
        return tags.isDisjoint(with: forbidden)
    }
}

enum CommandEffectProfiler {
    /// Verbs explicitly modeled by SemanticTagger. Mirrors its switch;
    /// a test pins the two together so they cannot drift apart silently.
    static let knownVerbs: Set<String> = [
        "ls", "cat", "head", "tail", "less", "more", "file", "stat",
        "df", "du", "ps", "pwd", "whoami", "uname", "uptime", "vm_stat",
        "which", "whereis", "find", "grep", "wc", "diff", "tree",
        "mkdir", "touch", "cp", "mv", "ln", "chmod", "chown", "tee", "truncate",
        "rm", "rmdir", "shred",
        "kill", "killall", "pkill", "reboot", "shutdown", "halt", "poweroff",
        "curl", "wget", "ssh", "scp", "sftp", "ftp", "nc", "telnet", "ping",
        "git",
        "brew", "apt", "apt-get", "yum", "dnf", "apk",
        "npm", "yarn", "pnpm", "pip", "pip3", "gem", "cargo",
        "docker", "echo",
    ]

    static func profile(command: String) -> CommandEffectProfile {
        let tags = SemanticTagger.tag(command: command)
        return CommandEffectProfile(tags: tags, knownVerb: allSegmentsKnown(command))
    }

    private static func allSegmentsKnown(_ command: String) -> Bool {
        var segments = [command]
        for op in ["&&", "||", ";", "|"] {
            segments = segments.flatMap { $0.components(separatedBy: op) }
        }
        let bodies = segments
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty })
        guard !bodies.isEmpty else { return false }
        return bodies.allSatisfy { segment in
            var words = segment.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return false }
            if words[0] == "sudo" { words.removeFirst() }
            guard let verb = words.first else { return false }
            return knownVerbs.contains(verb)
        }
    }
}
