//  LocalCandidateSource.swift
//  Bonk
//
//  Deterministic prefix completion from knownWords (recent terminal output).
//  Mirrors InlineCompletionService/SuggestionEngine knownWords logic verbatim for parity.
//

import Foundation
import os

/// KnownWords candidate — completes last token from `snapshot.knownWords`.
final class KnownWordsCandidateSource: SyncInlineCandidateSource, @unchecked Sendable {
    let name = "knownWords"

    func syncSuggestion(for snapshot: CommandContextSnapshot, typed: String) -> Suggestion? {
        guard typed.count >= 2 else { return nil }
        guard !typed.hasSuffix(" ") else { return nil }
        guard let lastToken = typed.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let token = String(lastToken)
        guard let match = snapshot.knownWords.first(where: {
            $0.lowercased().hasPrefix(token.lowercased()) && $0.count > token.count
        }) else { return nil }
        let suffix = String(match.dropFirst(token.count))
        guard !suffix.isEmpty else { return nil }
        // Pure token continuation — display exactly what will be inserted.
        return Suggestion(text: suffix, displayText: suffix)
    }
}

/// Smaller wrapper that sorts by shortest match (as original Service did).
final class SortedKnownWordsCandidateSource: SyncInlineCandidateSource, @unchecked Sendable {
    let name = "knownWordsSorted"

    func syncSuggestion(for snapshot: CommandContextSnapshot, typed: String) -> Suggestion? {
        guard typed.count >= 2 else { return nil }
        guard !typed.hasSuffix(" ") else { return nil }
        guard let lastToken = typed.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let token = String(lastToken)
        guard let match = snapshot.knownWords
            .filter({ $0.lowercased().hasPrefix(token.lowercased()) && $0.count > token.count })
            .sorted(by: { $0.count < $1.count })
            .first else { return nil }
        let suffix = String(match.dropFirst(token.count))
        // Pure token continuation — display exactly what will be inserted.
        return Suggestion(text: suffix, displayText: suffix)
    }
}

/// Static command vocabulary + PATH executables — completes the current token
/// when no richer candidate exists (e.g. "dock" → "docker"), Warp-style local
/// deterministic completion. Builtin list ships with the app; PATH executables
/// are scanned once in the background and merged in.
final class CommandVocabularySource: SyncInlineCandidateSource, @unchecked Sendable {
    let name = "vocabulary"
    private let vocabulary = CommandVocabulary.shared

    func syncSuggestion(for snapshot: CommandContextSnapshot, typed: String) -> Suggestion? {
        guard typed.count >= 2 else { return nil }
        // Vocabulary is strictly for root commands (before first argument space).
        guard !typed.contains(" ") else { return nil }
        let token = typed.trimmingCharacters(in: .whitespaces)
        guard let match = vocabulary.match(for: token) else { return nil }
        let suffix = String(match.dropFirst(token.count))
        guard !suffix.isEmpty else { return nil }
        // Pure token continuation — display exactly what will be inserted.
        return Suggestion(text: suffix, displayText: suffix)
    }
}

/// Process-wide command word set: builtin vocabulary + executables found on PATH.
final class CommandVocabulary: @unchecked Sendable {
    static let shared = CommandVocabulary()

    private let words = OSAllocatedUnfairLock<Set<String>>(initialState: CommandVocabulary.builtinWords)
    private let scanStarted = OSAllocatedUnfairLock<Bool>(initialState: false)

    private init() {
        refreshFromPATH()
    }

    /// Shortest vocabulary word that extends `token` (case-insensitive prefix).
    func match(for token: String) -> String? {
        let lower = token.lowercased()
        return words.withLock { all in
            var best: String?
            for word in all where word.count > token.count && word.lowercased().hasPrefix(lower) {
                if best == nil || word.count < best!.count { best = word }
            }
            return best
        }
    }

    /// Scan PATH directories once in the background; merge executable names.
    /// Names containing "." are skipped (they are rarely bare commands).
    private func refreshFromPATH() {
        let shouldScan = scanStarted.withLock { started -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldScan else { return }
        Task.detached(priority: .utility) { [weak self] in
            let searchPath = ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
            var collected = Set<String>()
            for directory in searchPath.split(separator: ":") {
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: String(directory)) {
                    for entry in entries where !entry.contains(".") {
                        collected.insert(entry)
                    }
                }
            }
            let found = collected
            guard let self, !found.isEmpty else { return }
            self.words.withLock { $0.formUnion(found) }
        }
    }

    /// Curated common commands — instant coverage before the PATH scan lands.
    static let builtinWords: Set<String> = [
        "ls", "cd", "pwd", "cat", "less", "more", "head", "tail", "grep", "rg",
        "find", "sed", "awk", "sort", "uniq", "wc", "cut", "tr", "xargs", "tee",
        "touch", "mkdir", "rmdir", "rm", "cp", "mv", "ln", "chmod", "chown",
        "chgrp", "df", "du", "tar", "zip", "unzip", "gzip", "gunzip", "curl",
        "wget", "ssh", "scp", "sftp", "rsync", "ping", "netstat", "lsof",
        "ifconfig", "dig", "nslookup", "traceroute", "nc", "telnet",
        "git", "docker", "kubectl", "helm", "terraform", "ansible", "vagrant",
        "make", "cmake", "brew", "port", "npm", "pnpm", "yarn", "npx", "node",
        "deno", "bun", "python", "python3", "pip", "pip3", "go", "cargo",
        "rustc", "java", "javac", "gradle", "mvn", "swift", "ruby", "gem",
        "php", "composer", "perl", "bash", "zsh", "fish", "sh",
        "vim", "vi", "nano", "emacs", "code", "open", "pbcopy", "pbpaste",
        "defaults", "launchctl", "diskutil", "hdiutil", "security", "spctl",
        "system_profiler", "softwareupdate", "kill", "killall", "top", "htop",
        "jobs", "bg", "fg", "nohup", "watch", "which", "whereis", "whoami",
        "id", "uname", "hostname", "uptime", "date", "cal", "echo", "printf",
        "export", "alias", "unalias", "source", "history", "clear", "man",
        "tldr", "file", "stat", "diff", "patch", "env", "printenv", "tmux",
        "screen", "jq", "yq", "sqlite3", "mysql", "psql", "redis-cli",
        "mongosh", "ffmpeg", "convert", "openssl", "uuidgen", "base64",
        "md5", "shasum", "gunzip", "lp", "lpstat", "networksetup", "scutil",
        "osascript", "plutil", "defaults", "xcodebuild", "xcrun", "simctl",
    ]
}
