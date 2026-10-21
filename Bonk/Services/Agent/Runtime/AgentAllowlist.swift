//
//  AgentAllowlist.swift
//  Bonk
//
//  Standing authorizations: "on this host, this command may run without
//  asking again".
//
//  **The scope is the host.** Bonk's agent runs on a remote machine, so an
//  authorization is an authorization *of that machine*. A rule that was not
//  scoped would carry "the user allowed `mkdir /tmp/x` here" across every
//  host the app has ever connected to — which is not what the user meant
//  and not what they were shown.
//
//  **A rule is an answer to "should I ask?", not a way around the policy.**
//  It turns a confirmation into a run. It never turns a refusal into a run:
//  a critical command stays blocked, and read-only mode stays read-only.
//
//  **Chained commands are not covered by a rule about their first part.**
//  `docker ps; rm -rf /` has two segments. A rule for `docker ps` says
//  nothing about the second, so it does not cover the command — matching
//  the whole string would let anything walk through a rule that covers
//  only its beginning.
//

import Foundation
import os

/// One standing authorization.
struct AgentAllowRule: Equatable, Codable, Sendable, Identifiable {
    let id: UUID
    /// The host the rule is scoped to. The host's stable identifier, never
    /// its display name: names change and are not unique.
    let hostScope: String
    /// The command the rule covers.
    let command: String
    /// Whether the command is a prefix or the whole thing.
    ///
    /// A prefix is only ever a `verb subcommand` pair — see
    /// `rulePrefix(for:)`. A rule that covers a whole command covers only
    /// that command.
    let isPrefix: Bool

    init(id: UUID = UUID(), hostScope: String, command: String, isPrefix: Bool = false) {
        self.id = id
        self.hostScope = hostScope
        self.command = command
        self.isPrefix = isPrefix
    }

    /// How the rule is shown to the user.
    var displayText: String {
        isPrefix ? "\(command) *" : command
    }
}

/// The standing authorizations, persisted across launches.
final class AgentAllowlist: @unchecked Sendable {
    /// The shared list.
    static let shared = AgentAllowlist()

    private static let storageKey = "ai_agent_allow_rules"
    private static let logger = Logger(subsystem: "com.bonk", category: "AgentAllowlist")

    private let lock = OSAllocatedUnfairLock<[AgentAllowRule]>(uncheckedState: [])
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.storageKey)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([AgentAllowRule].self, from: $0) }
        lock.withLock { $0 = stored ?? [] }
    }

    /// Every rule, for every host.
    var rules: [AgentAllowRule] {
        lock.withLock { $0 }
    }

    /// The rules that apply to one host.
    func rules(for hostScope: String) -> [AgentAllowRule] {
        rules.filter { $0.hostScope == hostScope }
    }

    /// Add a rule.
    ///
    /// Adding the same command twice is a no-op: the list is read by the
    /// user, and a duplicate is noise.
    @discardableResult
    func add(hostScope: String, command: String) -> AgentAllowRule {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AgentAllowRule(hostScope: hostScope, command: trimmed)
        }
        // A rule covers the `verb subcommand` prefix when the command has
        // that shape, and the whole command otherwise.
        let prefix = Self.rulePrefix(for: trimmed)
        let covered = prefix ?? trimmed
        let isPrefix = prefix != nil
        let existing = rules.first {
            $0.hostScope == hostScope && $0.command == covered && $0.isPrefix == isPrefix
        }
        if let existing { return existing }
        let rule = AgentAllowRule(
            hostScope: hostScope,
            command: covered,
            isPrefix: isPrefix
        )
        lock.withLock { $0.append(rule) }
        persist()
        return rule
    }

    /// Remove a rule.
    func remove(id: UUID) {
        lock.withLock { state in
            state.removeAll { $0.id == id }
        }
        persist()
    }

    /// Remove every rule for one host.
    func removeAll(for hostScope: String) {
        lock.withLock { state in
            state.removeAll { $0.hostScope == hostScope }
        }
        persist()
    }

    /// Does a standing authorization cover this command on this host?
    ///
    /// A rule for another host never covers anything here.
    func covers(command: String, hostScope: String) -> Bool {
        guard !hostScope.isEmpty else { return false }
        return rules(for: hostScope).contains { rule in
            Self.covers(rule: rule, target: command)
        }
    }

    /// Does the rule cover the command?
    ///
    /// A rule that covers a whole command covers only that command. A rule
    /// that covers a prefix covers the commands under it — and the command
    /// is split into its chain segments first, so **every** segment has to
    /// be covered. A rule for `docker ps` does not cover
    /// `docker ps; rm -rf /`: the second segment says nothing about the
    /// rule.
    static func covers(rule: AgentAllowRule, target: String) -> Bool {
        let allowed = rule.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !allowed.isEmpty else { return false }
        if !rule.isPrefix {
            return CommandNormalizer.normalizedKey(allowed)
                == CommandNormalizer.normalizedKey(target)
        }
        let segments = CommandSafety.splitByChainOperators(target)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            segmentMatches(prefix: allowed, segment: segment.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The prefix a rule may cover for this command, or nil when the rule
    /// has to cover the whole command.
    ///
    /// A prefix is only offered for the shape `verb subcommand`: two words,
    /// the second one a subcommand rather than a flag, a file name, a path
    /// or a number. `git commit -m "..."` yields `git commit`; `rm -rf /tmp/x`
    /// yields nothing, because `rm` with a flag is exactly the shape a
    /// prefix rule must not cover — a prefix on it would also cover
    /// `rm -rf /tmp/x cache`, which is a different command and deletes
    /// more.
    ///
    /// A command that starts with a shell wrapper yields nothing for the
    /// same reason: a prefix on `env` would cover `env bash -c ...`.
    static func rulePrefix(for command: String) -> String? {
        let tokens = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        // An environment assignment in front changes what the command is;
        // there is no safe prefix to read off it.
        if let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            return nil
        }
        guard tokens.count >= 2 else { return nil }
        let verb = tokens[0]
        let subcommand = tokens[1]
        guard !dangerousWrappers.contains(verb.lowercased()) else { return nil }
        guard subcommand.range(of: "^[a-z][a-z0-9]*(-[a-z0-9]+)*$", options: .regularExpression) != nil
        else { return nil }
        return "\(verb) \(subcommand)"
    }

    /// Wrappers a prefix rule must never cover.
    ///
    /// A prefix on one of these would cover arbitrary code: `env bash -c
    /// ...` runs whatever it is told to, and `sudo` on a prefix would
    /// auto-approve future privileged invocations.
    static let dangerousWrappers: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "tcsh", "ksh", "dash",
        "cmd", "powershell", "pwsh",
        "env", "xargs",
        "nice", "stdbuf", "nohup", "timeout", "time",
        "sudo", "doas", "pkexec"
    ]

    /// Does one segment start with the allowed prefix, at a word boundary?
    private static func segmentMatches(prefix: String, segment: String) -> Bool {
        guard segment.hasPrefix(prefix) else { return false }
        let rest = segment.dropFirst(prefix.count)
        guard !rest.isEmpty else { return true }
        // The prefix has to end at a word boundary: `docker ps` must not
        // cover `docker psx`.
        return rest.hasPrefix(" ") || rest.hasPrefix("\t")
    }

    /// Write the list out.
    private func persist() {
        let current = rules
        guard let data = try? JSONEncoder().encode(current),
              let json = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(json, forKey: Self.storageKey)
        Self.logger.debug("Stored \(current.count, privacy: .public) allow rule(s)")
    }
}
