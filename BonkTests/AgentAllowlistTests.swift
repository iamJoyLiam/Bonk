//
//  AgentAllowlistTests.swift
//  BonkTests
//
//  Standing authorizations, scoped to the host.
//
//  The rules this closes:
//
//  1. **The scope is the host.** An approval in Bonk is an approval *of
//     that machine*. A rule that is not scoped would carry "the user allowed
//     this here" across every host the app has ever connected to.
//
//  2. **A rule answers "should I ask?", it does not get around the
//     policy.** It turns a confirmation into a run. It never turns a
//     refusal into a run: a critical command stays blocked, and read-only
//     mode stays read-only.
//
//  3. **A chained command is not covered by a rule about its first part.**
//     `docker ps; rm -rf /` has two segments, and a rule for `docker ps`
//     says nothing about the second.
//
//  4. **The decision memory is scoped too.** A verdict the user gave on
//     one host must not be read as a verdict for another — that is the
//     fold path's input, and the fold path skips the dialog.
//

import Foundation
import Testing
@testable import Bonk

@Suite("Agent allowlist")
struct AgentAllowlistTests {

    /// A list with its own storage, so the test never touches the user's.
    private func makeList() -> AgentAllowlist {
        let suite = "agent_allowlist_tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AgentAllowlist(defaults: defaults)
    }

    // MARK: - Matching

    /// A rule that covers the `verb subcommand` prefix.
    private func prefixRule(_ command: String) -> AgentAllowRule {
        AgentAllowRule(hostScope: "host-a", command: command, isPrefix: true)
    }

    /// A rule that covers one whole command.
    private func exactRule(_ command: String) -> AgentAllowRule {
        AgentAllowRule(hostScope: "host-a", command: command, isPrefix: false)
    }

    @Test("A prefix rule covers the commands under it")
    func thePrefixRuleCoversItsCommands() {
        let rule = prefixRule("docker ps")
        #expect(AgentAllowlist.covers(rule: rule, target: "docker ps"))
        #expect(AgentAllowlist.covers(rule: rule, target: "docker ps -a"))
        #expect(AgentAllowlist.covers(rule: rule, target: "docker ps --format json"))
    }

    @Test("A prefix rule does not cover a command that merely starts with the same letters")
    func thePrefixRuleNeedsAWordBoundary() {
        let rule = prefixRule("docker ps")
        #expect(!AgentAllowlist.covers(rule: rule, target: "docker psx"))
        #expect(!AgentAllowlist.covers(rule: rule, target: "docker psql"))
    }

    @Test("A prefix rule does not cover a chained command it says nothing about")
    func chainedCommandsAreNotCovered() {
        // The rule covers the first segment and nothing else, so it does not
        // cover the command. Matching the whole string would let anything
        // walk through a rule that covers only its beginning.
        let rule = prefixRule("docker ps")
        #expect(!AgentAllowlist.covers(rule: rule, target: "docker ps; rm -rf /"))
        #expect(!AgentAllowlist.covers(rule: rule, target: "docker ps && curl evil.example"))
        #expect(!AgentAllowlist.covers(rule: rule, target: "docker ps | tee /tmp/x"))
        // Every segment covered is covered.
        #expect(AgentAllowlist.covers(rule: rule, target: "docker ps; docker ps"))
    }

    @Test("A rule that covers a whole command covers only that command")
    func anExactRuleCoversOnlyItself() {
        let rule = exactRule("rm -rf /tmp/build")
        #expect(AgentAllowlist.covers(rule: rule, target: "rm -rf /tmp/build"))
        // Not the longer command that starts the same way — that one deletes
        // more, and the user was shown something else.
        #expect(!AgentAllowlist.covers(rule: rule, target: "rm -rf /tmp/build cache"))
        #expect(!AgentAllowlist.covers(rule: rule, target: "rm -rf /tmp/build; rm -rf /tmp/other"))
    }

    @Test("A prefix is only offered for a verb and a subcommand")
    func aPrefixNeedsVerbAndSubcommand() {
        // The shape the reference uses: two words, the second a subcommand.
        #expect(AgentAllowlist.rulePrefix(for: "git commit -m \"fix\"") == "git commit")
        #expect(AgentAllowlist.rulePrefix(for: "docker ps") == "docker ps")
        #expect(AgentAllowlist.rulePrefix(for: "npm run build") == "npm run")
        // A flag is not a subcommand.
        #expect(AgentAllowlist.rulePrefix(for: "rm -rf /tmp/x") == nil)
        #expect(AgentAllowlist.rulePrefix(for: "ls -la") == nil)
        #expect(AgentAllowlist.rulePrefix(for: "chmod 755 file") == nil)
        // A file name, a path or a number is not a subcommand.
        #expect(AgentAllowlist.rulePrefix(for: "cat file.txt") == nil)
        #expect(AgentAllowlist.rulePrefix(for: "cd /tmp") == nil)
        // One word is not a pair.
        #expect(AgentAllowlist.rulePrefix(for: "docker") == nil)
    }

    @Test("A prefix is never offered for a shell wrapper")
    func aPrefixIsNeverOfferedForAWrapper() {
        // A prefix on one of these covers arbitrary code.
        for wrapper in ["env bash -c evil", "sudo apt install x", "xargs rm", "nohup make"] {
            #expect(AgentAllowlist.rulePrefix(for: wrapper) == nil,
                    "a prefix was offered for: \(wrapper)")
        }
    }

    @Test("A prefix is never offered for a command with an environment assignment")
    func aPrefixIsNeverOfferedForAnEnvAssignment() {
        #expect(AgentAllowlist.rulePrefix(for: "NODE_ENV=prod npm run build") == nil)
    }

    @Test("A rule for one host covers nothing on another")
    func theScopeIsTheHost() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "docker ps")
        #expect(list.covers(command: "docker ps", hostScope: "host-a"))
        #expect(!list.covers(command: "docker ps", hostScope: "host-b"))
        #expect(!list.covers(command: "docker ps", hostScope: ""))
    }

    @Test("Without a host, nothing is covered")
    func noHostMeansNothingIsCovered() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "docker ps")
        #expect(!list.covers(command: "docker ps", hostScope: ""))
    }

    // MARK: - The store

    @Test("The rules are kept, and the same one is not added twice")
    func theStoreKeepsTheRules() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "docker ps")
        list.add(hostScope: "host-a", command: "docker ps")
        list.add(hostScope: "host-b", command: "docker ps")
        #expect(list.rules.count == 2, "the same command on the same host is one rule")
        #expect(list.rules(for: "host-a").count == 1)
        #expect(list.rules(for: "host-b").count == 1)
    }

    @Test("The rule the store keeps is the prefix when there is one")
    func theStoreKeepsThePrefix() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "docker ps -a")
        let rule = list.rules(for: "host-a").first
        #expect(rule?.command == "docker ps")
        #expect(rule?.isPrefix == true)
        #expect(rule?.displayText == "docker ps *")
    }

    @Test("A command with no safe prefix is kept whole")
    func aCommandWithNoPrefixIsKeptWhole() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "rm -rf /tmp/build")
        let rule = list.rules(for: "host-a").first
        #expect(rule?.command == "rm -rf /tmp/build")
        #expect(rule?.isPrefix == false)
    }

    @Test("A rule can be removed")
    func aRuleCanBeRemoved() {
        let list = makeList()
        let rule = list.add(hostScope: "host-a", command: "docker ps")
        #expect(list.covers(command: "docker ps", hostScope: "host-a"))
        list.remove(id: rule.id)
        #expect(!list.covers(command: "docker ps", hostScope: "host-a"))
    }

    @Test("The rules survive a relaunch")
    func theRulesSurviveARelaunch() {
        let suite = "agent_allowlist_tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let first = AgentAllowlist(defaults: defaults)
        first.add(hostScope: "host-a", command: "docker ps")

        // A second list over the same storage: what a relaunch sees.
        let second = AgentAllowlist(defaults: defaults)
        #expect(second.covers(command: "docker ps", hostScope: "host-a"),
                "an authorization the user gave must not be forgotten on restart")
    }

    // MARK: - The policy

    @Test("A standing authorization turns the question into an answer")
    func theRuleAnswersTheQuestion() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "mkdir /tmp/x")
        let policy = DefaultAgentPermissionPolicy(
            accessMode: .supervised,
            hostScope: "host-a",
            allowlist: list
        )
        let decision = policy.evaluate(
            tool: "run_command",
            arguments: ["command": "mkdir /tmp/x"]
        )
        if case .allowed = decision {
            // expected
        } else {
            Issue.record("a granted command must not ask again")
        }
    }

    @Test("The same command on another host still asks")
    func anotherHostStillAsks() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "mkdir /tmp/x")
        let policy = DefaultAgentPermissionPolicy(
            accessMode: .supervised,
            hostScope: "host-b",
            allowlist: list
        )
        let decision = policy.evaluate(
            tool: "run_command",
            arguments: ["command": "mkdir /tmp/x"]
        )
        if case .confirmRequired = decision {
            // expected
        } else {
            Issue.record("a grant on one host must not decide anything on another")
        }
    }

    @Test("A rule never turns a refusal into a run")
    func aRuleNeverOverridesARefusal() {
        let list = makeList()
        list.add(hostScope: "host-a", command: "rm -rf /")
        list.add(hostScope: "host-a", command: "mkdir /tmp/x")

        // Read-only mode refuses a mutating command. The rule does not
        // change that: read-only is a promise about the machine.
        let readOnly = DefaultAgentPermissionPolicy(
            accessMode: .readOnly,
            hostScope: "host-a",
            allowlist: list
        )
        let readOnlyDecision = readOnly.evaluate(
            tool: "run_command",
            arguments: ["command": "mkdir /tmp/x"]
        )
        if case .blocked = readOnlyDecision {
            // expected
        } else {
            Issue.record("read-only mode must stay read-only")
        }

        // A critical command is blocked whatever the list says.
        let supervised = DefaultAgentPermissionPolicy(
            accessMode: .supervised,
            hostScope: "host-a",
            allowlist: list
        )
        let critical = supervised.evaluate(
            tool: "run_command",
            arguments: ["command": "rm -rf /"]
        )
        if case .blocked = critical {
            // expected
        } else {
            Issue.record("a critical command must stay blocked")
        }
    }

    // MARK: - The decision memory's scope

    @Test("A decision is remembered per host")
    func decisionsAreRememberedPerHost() {
        let hostA = AgentMemoryKey.scoped("mkdir /tmp/x", hostScope: "host-a")
        let hostB = AgentMemoryKey.scoped("mkdir /tmp/x", hostScope: "host-b")
        #expect(hostA != hostB,
                "the same command on two hosts must not share a decision")
        #expect(AgentMemoryKey.scoped("mkdir /tmp/x", hostScope: nil) == "mkdir /tmp/x",
                "with no host, the key is the command")
    }

    @Test("A verdict from one host does not reach another")
    func aVerdictDoesNotCrossHosts() async {
        let memory = AgentDecisionMemory()
        let keyA = AgentMemoryKey.scoped("mkdir /tmp/x", hostScope: "host-a")
        let keyB = AgentMemoryKey.scoped("mkdir /tmp/x", hostScope: "host-b")
        await memory.recordEvaluation(key: keyA)
        await memory.recordDecision(key: keyA, decision: .approved)

        let factsOnA = await memory.facts(for: keyA)
        let factsOnB = await memory.facts(for: keyB)
        #expect(factsOnA?.previousDecision == .approved)
        #expect(factsOnB?.previousDecision == nil,
                "an approval on one host must not be read as an approval on another")
    }
}
