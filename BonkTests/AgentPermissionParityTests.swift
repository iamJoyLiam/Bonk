//
//  AgentPermissionParityTests.swift
//  BonkTests
//
//  One permission policy for both agent paths.
//
//  The defect: the tool loop decided with `DefaultAgentPermissionPolicy`,
//  which honours the user's access mode. The plan path decided from the
//  step's own risk level and nothing else, so the access mode was never
//  consulted there. Two consequences, in opposite directions:
//
//    read-only   the tool loop refuses a mutating command; the plan path
//                asked the user to confirm it, and ran it if they said yes.
//                "Read-only" was not read-only.
//    full access the tool loop runs a mutating command without asking; the
//                plan path still asked. The user set "autonomous" and got
//                a dialog.
//
//  The same command, two different rules, depending on which path ran it.
//
//  These tests drive the real plan path — `AgentEngine.runAgent` → plan →
//  approval → `executePlan` — and assert against what the engine actually
//  did.
//

import Foundation
import os
import Testing
@testable import Bonk

// MARK: - Doubles

/// Answers with a fixed plan. Cannot tool-call, so the agent takes the
/// plan path rather than the tool loop.
final class PlanAnsweringProvider: LLMProvider, @unchecked Sendable {
    private let answer: String
    private let toolCallCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    var toolCalls: Int { toolCallCount.withLock { $0 } }

    let providerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    let providerName = "plan-answering"
    let capability = ModelCapability(
        supportsChatCompletions: true,
        supportsStreaming: true
    )

    init(answer: String) {
        self.answer = answer
    }

    func chat(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> LLMResponse {
        LLMResponse(text: answer)
    }

    func stream(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func toolCall(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int?
    ) async throws -> LLMResponse {
        toolCallCount.withLock { $0 += 1 }
        return LLMResponse(text: "tool")
    }

    func listModels() async throws -> [String] { ["plan"] }
    func testConnection() async throws -> Bool { true }
}

/// Hands out the plan provider for every workload.
final class PlanProviderResolver: LLMProviderResolving {
    private let provider: any LLMProvider

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    func provider(
        for config: AIProviderConfig,
        apiKey: String,
        workload: AIWorkload
    ) -> any LLMProvider {
        provider
    }
}

/// A host key store that remembers nothing. Nothing connects in these tests.
struct ParityHostKeyStore: SSHHostKeyStore {
    func knownFingerprint(for host: String, port: UInt16) async -> SSHHostFingerprint? { nil }
    func saveFingerprint(_ fingerprint: SSHHostFingerprint, for host: String, port: UInt16) async {}
}

@Suite("Agent permission parity")
struct AgentPermissionParityTests {

    /// A mutating command: L2, "state mutation".
    private static let mutatingCommand = "mkdir /tmp/bonk-perity-probe"

    /// What the engine said about the step.
    private struct Outcome {
        var askedForConfirmation = false
        var attemptedExecution = false
        var blocked = false
    }

    @MainActor
    private func runPlan(
        accessMode: AgentMessage.AccessMode,
        command: String
    ) async -> Outcome {
        let plan = """
        {"response":"Doing it.","plan":[{"description":"probe step","command":"\(command)"}]}
        """
        let provider = PlanAnsweringProvider(answer: plan)
        let store = AIProviderStore()
        // Ollama: needs no API key, so the test never writes to the
        // Keychain, and it cannot tool-call, so the plan path is taken.
        let config = AIProviderConfig(
            name: "local",
            type: .ollama,
            model: "probe-model",
            endpoint: "https://example.invalid"
        )
        store.providers = [config]
        store.activeProviderID = config.id

        let engine = AgentEngine(
            providerStore: store,
            providerResolver: PlanProviderResolver(provider: provider),
            permissionPolicyFactory: { _ in
                DefaultAgentPermissionPolicy(accessMode: accessMode)
            }
        )
        engine.activeProvider = config

        let runner = Task { @MainActor in
            await engine.runAgent(
                input: "do the thing",
                sshService: SSHNetworkService(hostKeyStore: ParityHostKeyStore()),
                conversation: nil,
                context: nil
            )
        }

        // Approve the plan when it appears. The plan approval is a
        // continuation the UI resumes; this is the UI.
        await approvePlanWhenReady(engine)

        // Watch for a per-step confirmation while the plan runs.
        var outcome = Outcome()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let pending = engine.pendingConfirmation {
                outcome.askedForConfirmation = true
                pending.continuation(true)
            }
            if outcome.attemptedExecution || outcome.blocked { break }
            let messages = engine.agentMessages
            if messages.contains(where: { $0.content.contains("Not connected to any host.") }) {
                outcome.attemptedExecution = true
                break
            }
            if messages.contains(where: {
                $0.role == .system && $0.content.contains(command)
                    && !$0.content.contains("Not connected to any host.")
            }) {
                outcome.blocked = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        await runner.value
        return outcome
    }

    @MainActor
    private func approvePlanWhenReady(_ engine: AgentEngine) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if engine.currentPlan != nil {
                engine.approvePlan()
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Behavioural: the plan path honours the access mode

    @Test("Read-only mode refuses a mutating step instead of asking about it")
    @MainActor
    func readOnlyRefusesMutatingStep() async {
        let outcome = await runPlan(
            accessMode: .readOnly,
            command: Self.mutatingCommand
        )
        #expect(!outcome.askedForConfirmation,
                "read-only must not offer to run a mutating command")
        #expect(!outcome.attemptedExecution,
                "read-only must not run a mutating command")
        #expect(outcome.blocked, "the step must be recorded as blocked")
    }

    @Test("Full access runs a mutating step without asking")
    @MainActor
    func fullAccessRunsMutatingStep() async {
        let outcome = await runPlan(
            accessMode: .fullAccess,
            command: Self.mutatingCommand
        )
        #expect(!outcome.askedForConfirmation,
                "full access is autonomous — it must not ask")
        #expect(outcome.attemptedExecution,
                "full access must reach the command")
    }

    @Test("Supervised mode still asks before a mutating step")
    @MainActor
    func supervisedAsksBeforeMutatingStep() async {
        let outcome = await runPlan(
            accessMode: .supervised,
            command: Self.mutatingCommand
        )
        #expect(outcome.askedForConfirmation,
                "supervised mode must ask before a mutating command")
    }

    @Test("A read-only command runs on every access mode")
    @MainActor
    func readOnlyCommandAlwaysRuns() async {
        for mode in [AgentMessage.AccessMode.readOnly,
                     .supervised,
                     .fullAccess] {
            let outcome = await runPlan(accessMode: mode, command: "ls -la /tmp")
            #expect(!outcome.askedForConfirmation,
                    "\(mode.rawValue) must not ask about a read-only command")
            #expect(outcome.attemptedExecution,
                    "\(mode.rawValue) must run a read-only command")
        }
    }

    // MARK: - Pure: the policy both paths now share

    @Test("The shared policy decides by access mode")
    func policyDecidesByAccessMode() {
        let command = Self.mutatingCommand

        let readOnly = DefaultAgentPermissionPolicy(accessMode: .readOnly)
            .evaluate(tool: "run_command", arguments: ["command": command])
        if case .blocked = readOnly {
            // expected
        } else {
            Issue.record("read-only must refuse a mutating command")
        }

        let supervised = DefaultAgentPermissionPolicy(accessMode: .supervised)
            .evaluate(tool: "run_command", arguments: ["command": command])
        if case .confirmRequired = supervised {
            // expected
        } else {
            Issue.record("supervised must ask about a mutating command")
        }

        let full = DefaultAgentPermissionPolicy(accessMode: .fullAccess)
            .evaluate(tool: "run_command", arguments: ["command": command])
        if case .allowed = full {
            // expected
        } else {
            Issue.record("full access must allow a mutating command")
        }
    }

    @Test("The two paths classify a command identically")
    func bothPathsClassifyIdentically() {
        // The plan path's risk level and the policy's level come from the
        // same classifier. If that ever stops being true, the two paths
        // would drift again.
        for command in ["ls -la", "mkdir /tmp/x", "rm -rf /tmp/x", "curl https://example.com", ""] {
            #expect(
                CommandSafety.classifyLevel(command) == CommandSafety.classify(command).level,
                "the two classifiers disagree on: \(command)"
            )
        }
    }

    // MARK: - Wiring guard

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("The plan path decides through the shared policy")
    func planPathUsesTheSharedPolicy() throws {
        let plan = try source("Bonk/Services/Agent/AgentPlanExecutor.swift")
        #expect(plan.contains("permissionPolicyFactory(hostScope)"),
                "the plan path must decide through the shared policy")
        // The old decision: the step's own risk level, with no access mode
        // anywhere in sight.
        #expect(!plan.contains("if step.riskLevel == .blocked"),
                "the plan path must not decide from the risk level alone")
        #expect(!plan.contains("if !step.isAutoExecutable"),
                "the plan path must not decide from the risk level alone")
    }

    @Test("The tool loop and the plan path build their policy the same way")
    func bothPathsBuildTheirPolicyTheSameWay() throws {
        let toolLoop = try source("Bonk/Services/Agent/AgentToolExecutor.swift")
        #expect(toolLoop.contains("permissionPolicyFactory(hostScope)"),
                "the tool loop must build its policy through the same factory")
    }
}
