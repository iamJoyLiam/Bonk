//
//  AgentProviderResolutionTests.swift
//  BonkTests
//
//  One provider resolution per agent run.
//
//  The defect: the agent path resolved the provider three times, through two
//  different mechanisms.
//
//      the decision (tool loop or plan flow)   resolveProvider()      — active
//      the tool loop                           resolveAgentProvider() — routed
//      the plan flow                           resolveProvider()      — active
//
//  The decision and the run were therefore made against different providers.
//  The router filters out providers that cannot tool-call, so with a
//  non-tool-capable provider active the decision said "plan flow" even when
//  the router had a tool-capable provider ready and waiting. The tool loop
//  was unreachable for those users.
//
//  A fourth problem: the tool loop built its provider with
//  `LLMProviderFactory.provider(...)` directly, bypassing the injectable
//  resolver — the one seam the factory's own comment says every provider is
//  supposed to be built through. That made the agent path impossible to
//  exercise with a substituted provider.
//
//  These tests drive the real `AgentEngine.runAgent` and assert against a
//  resolver that counts what it was asked for.
//

import Foundation
import os
import Testing
@testable import Bonk

// MARK: - Doubles

/// Records which way the agent path called the provider.
final class AgentPathCapturingProvider: LLMProvider, @unchecked Sendable {
    private let toolCallCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
    private let chatCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    var toolCalls: Int { toolCallCount.withLock { $0 } }
    var chats: Int { chatCount.withLock { $0 } }

    let providerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    let providerName = "capturing"
    let capability: ModelCapability

    init(capability: ModelCapability? = nil) {
        self.capability = capability ?? ModelCapability(
            supportsChatCompletions: true,
            supportsStreaming: true,
            supportsToolCalls: true
        )
    }

    func chat(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> LLMResponse {
        chatCount.withLock { $0 += 1 }
        return LLMResponse(text: "chat")
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

    func listModels() async throws -> [String] { ["capturing"] }
    func testConnection() async throws -> Bool { true }
}

/// Counts the providers the resolver built, per workload.
///
/// The capability of each provider it hands out is the one the real factory
/// would resolve for that config, so a test can still say "this provider
/// cannot tool-call". A stub with a fixed capability could not express the
/// case the defect lived in.
final class CountingProviderResolver: LLMProviderResolving {
    private let workloads = OSAllocatedUnfairLock<[AIWorkload]>(uncheckedState: [])
    private let providers = OSAllocatedUnfairLock<[any LLMProvider]>(uncheckedState: [])

    var builtFor: [AIWorkload] { workloads.withLock { $0 } }
    var built: [any LLMProvider] { providers.withLock { $0 } }

    /// How many times any provider it built was asked to tool-call.
    var toolCalls: Int {
        built.compactMap { ($0 as? AgentPathCapturingProvider)?.toolCalls }.reduce(0, +)
    }

    /// How many times any provider it built was asked to chat.
    var chats: Int {
        built.compactMap { ($0 as? AgentPathCapturingProvider)?.chats }.reduce(0, +)
    }

    func provider(
        for config: AIProviderConfig,
        apiKey: String,
        workload: AIWorkload
    ) -> any LLMProvider {
        let capability = AIProviderCapabilityResolver
            .resolve(config: config, workload: workload)
            .capability
        let provider = AgentPathCapturingProvider(capability: capability)
        workloads.withLock { $0.append(workload) }
        providers.withLock { $0.append(provider) }
        return provider
    }
}

/// A host key store that remembers nothing. The agent path never connects
/// in these tests — the model is asked a question it answers without tools.
struct NullHostKeyStore: SSHHostKeyStore {
    func knownFingerprint(for host: String, port: UInt16) async -> SSHHostFingerprint? { nil }
    func saveFingerprint(_ fingerprint: SSHHostFingerprint, for host: String, port: UInt16) async {}
}

@Suite("Agent provider resolution")
struct AgentProviderResolutionTests {

    /// A provider that cannot tool-call.
    ///
    /// Ollama's default capability has no tool calls, and the type does not
    /// require an API key — so this test never writes to the Keychain. That
    /// matters: `AIProviderConfig.init` stores the key it is given, so a
    /// test that passes one leaves an entry behind that nobody owns.
    private static func planOnlyProvider() -> AIProviderConfig {
        AIProviderConfig(
            name: "plan-only",
            type: .ollama,
            model: "probe-model",
            endpoint: "https://example.invalid"
        )
    }

    /// A provider that can tool-call, for the same reason.
    private static func toolCapableProvider() -> AIProviderConfig {
        AIProviderConfig(
            name: "tool-capable",
            type: .custom,
            model: "probe-model",
            endpoint: "https://example.invalid"
        )
    }

    @MainActor
    private func makeEngine(
        resolver: CountingProviderResolver,
        providers: [AIProviderConfig],
        activeID: UUID?
    ) -> AgentEngine {
        let store = AIProviderStore()
        store.providers = providers
        store.activeProviderID = activeID
        let engine = AgentEngine(providerStore: store, providerResolver: resolver)
        return engine
    }

    // MARK: - Behavioural

    @Test("The tool loop's provider is built once, and the tool loop is what runs")
    @MainActor
    func toolLoopProviderIsBuiltOnceAndUsed() async {
        let resolver = CountingProviderResolver()
        let toolCapable = Self.toolCapableProvider()
        let engine = makeEngine(
            resolver: resolver,
            providers: [toolCapable],
            activeID: toolCapable.id
        )
        engine.activeProvider = toolCapable

        await engine.runAgent(
            input: "how much disk is free?",
            sshService: SSHNetworkService(hostKeyStore: NullHostKeyStore()),
            conversation: nil,
            context: nil
        )

        #expect(resolver.builtFor.filter { $0 == .agentToolLoop }.count == 1,
                "the agent provider must be built once per run, not once per use")
        #expect(resolver.toolCalls == 1, "the tool loop is what should have run")
        #expect(resolver.chats == 0, "the plan flow ran instead of the tool loop")
    }

    @Test("A tool-capable provider is reachable even when the active one cannot tool-call")
    @MainActor
    func toolLoopIsReachableDespiteAnIncapableActiveProvider() async {
        // The defect. The router filters out providers that cannot tool-call,
        // so the active plan-only provider never reaches the tool loop —
        // but another configured provider can. The decision used to be made on
        // the active provider alone, so the tool loop was never chosen.
        let resolver = CountingProviderResolver()
        let planOnly = Self.planOnlyProvider()
        let toolCapable = Self.toolCapableProvider()
        let engine = makeEngine(
            resolver: resolver,
            providers: [planOnly, toolCapable],
            activeID: planOnly.id
        )
        engine.activeProvider = planOnly

        await engine.runAgent(
            input: "how much disk is free?",
            sshService: SSHNetworkService(hostKeyStore: NullHostKeyStore()),
            conversation: nil,
            context: nil
        )

        #expect(resolver.toolCalls == 1,
                "the tool loop must be reachable when a tool-capable provider exists")
    }

    @Test("With no tool-capable provider at all, the plan flow is used")
    @MainActor
    func planFlowIsUsedWhenNothingCanToolCall() async {
        let resolver = CountingProviderResolver()
        let planOnly = Self.planOnlyProvider()
        let engine = makeEngine(
            resolver: resolver,
            providers: [planOnly],
            activeID: planOnly.id
        )
        engine.activeProvider = planOnly

        await engine.runAgent(
            input: "how much disk is free?",
            sshService: SSHNetworkService(hostKeyStore: NullHostKeyStore()),
            conversation: nil,
            context: nil
        )

        #expect(resolver.toolCalls == 0, "no provider can tool-call")
        #expect(resolver.chats > 0, "the plan flow should have run")
    }

    // MARK: - Wiring guard

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("No agent file builds a provider outside the resolver seam")
    func noFileBypassesTheResolver() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Bonk/Services/Agent")
        let offenders: [String] = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .compactMap { name -> String? in
                let source = try String(
                    contentsOf: root.appendingPathComponent(name),
                    encoding: .utf8
                )
                // Strip line comments so prose about the factory is not a hit.
                let code = source
                    .split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                // The factory is the default implementation behind the
                // resolver. Calling it directly bypasses the seam, which is
                // what the resolver exists for.
                guard code.contains("LLMProviderFactory.provider(") else { return nil }
                return name
            }
        #expect(offenders.isEmpty,
                "these files build a provider outside the resolver seam: \(offenders)")
    }

    @Test("The agent path resolves the provider exactly once per run")
    func agentPathResolvesOnce() throws {
        let plan = try source("Bonk/Services/Agent/AgentPlanExecutor.swift")
        let toolLoop = try source("Bonk/Services/Agent/AgentToolExecutor.swift")
        #expect(!toolLoop.contains("resolveAgentProvider("),
                "the tool loop must not resolve the provider itself")
        #expect(!toolLoop.contains("resolveProvider("),
                "the tool loop must not resolve the provider itself")
        #expect(plan.contains("resolvedProvider:"),
                "the plan flow must take the resolved provider rather than resolve its own")
    }
}
