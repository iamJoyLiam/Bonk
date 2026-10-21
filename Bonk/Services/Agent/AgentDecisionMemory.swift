//  AgentDecisionMemory.swift
//  Bonk
//
//  Phase 1 per-command decision memory. Records FACTS about past user
//  decisions keyed by normalized command — never model judgments, never
//  "this command is safe". Phase 2 reads previousUserDecision /
//  sameCommandOccurrences to decide fold eligibility.

import Foundation

/// Recorded user verdict. Deliberately narrow: what the user did.
enum RecordedUserDecision: String, Sendable {
    case approved
    case denied
}

/// The key a decision is remembered under.
enum AgentMemoryKey {
    /// Scope a key to the host it was decided on.
    ///
    /// An authorization is an authorization *of one machine*. Without the
    /// scope, a verdict the user gave on one host — "yes, run
    /// `mkdir /tmp/x` there" — would be read as a verdict for every other
    /// host the app has ever connected to.
    ///
    /// The scope goes in front, behind a separator that cannot occur in a
    /// normalized command, so two different (host, command) pairs can never
    /// produce the same key.
    static func scoped(_ key: String, hostScope: String?) -> String {
        guard let hostScope, !hostScope.isEmpty else { return key }
        return "\(hostScope)\u{1F}\(key)"
    }
}

/// Aggregate facts for one normalized command key.
struct CommandDecisionFacts: Sendable, Equatable {
    var occurrences = 0
    var allowCount = 0
    var denyCount = 0
    var previousDecision: RecordedUserDecision?
    var lastDecisionAt: Date?
}

/// In-memory per-command decision facts. Engine-owned, cross-run.
/// Persistence is a later phase; Phase 1 only needs recording + lookup.
actor AgentDecisionMemory {
    private var facts: [String: CommandDecisionFacts] = [:]

    /// Records that a confirm gate was evaluated (folded or shown).
    func recordEvaluation(key: String) {
        facts[key, default: CommandDecisionFacts()].occurrences += 1
    }

    /// Records the user's verdict.
    func recordDecision(key: String, decision: RecordedUserDecision) {
        var entry = facts[key, default: CommandDecisionFacts()]
        switch decision {
        case .approved: entry.allowCount += 1
        case .denied: entry.denyCount += 1
        }
        entry.previousDecision = decision
        entry.lastDecisionAt = Date()
        facts[key] = entry
    }

    func facts(for key: String) -> CommandDecisionFacts? {
        facts[key]
    }

    func reset() {
        facts = [:]
    }
}
