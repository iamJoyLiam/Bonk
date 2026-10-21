import Foundation
import os.log
import SwiftData

/// Central AI agent engine. Manages all three modes (Ask/Edit/Agent)
/// with unified state, request building, and safety controls.
@Observable @MainActor
final class AgentEngine {
    static let shared = AgentEngine()

    /// Cap on tool-loop rounds before the agent synthesizes answer. Configurable in preferences (default 25).
    static var maxAgentIterations: Int {
        let val = UserDefaults.standard.integer(forKey: "ai_agent_max_iterations")
        return val > 0 ? val : 25
    }

    /// Access mode for agent tool execution (Full Access, Supervised, Read-Only).
    ///
    /// Not main-actor isolated: it reads a preference, and the permission
    /// policy factory is called from a `Sendable` closure. Reading
    /// `UserDefaults.standard` is thread-safe.
    nonisolated static var accessMode: AgentMessage.AccessMode {
        let raw = UserDefaults.standard.string(forKey: "ai_agent_access_mode") ?? ""
        return AgentMessage.AccessMode(rawValue: raw) ?? .supervised
    }

    // MARK: - Unified State

    var isProcessing = false
    var streamingResponse = ""
    var currentExplanation: String?
    var lastError: String?
    var activeProvider: AIProviderConfig?

    // Agent-specific state
    var agentMessages: [AgentMessage] = []
    /// The host the current run is against, by stable identifier.
    ///
    /// Set for the duration of a run so the confirmation dialog can scope a
    /// standing authorization to the right machine.
    var activeRunHostScope: String?
    /// The task list the model last wrote, if it wrote one.
    ///
    /// The model owns this list; the app only shows it.
    var currentTodos: [AgentTodoItem]?
    var pendingConfirmation: PendingCommand?
    var activeRuntime: AgentRuntime?
    /// Cross-run per-command decision facts (Phase 1: record only).
    let decisionMemory = AgentDecisionMemory()
    /// Model-facing conversation history for the agent loop.
    ///
    /// Distinct from `agentMessages`, which is the transcript the user reads.
    /// This is what the model sees: the turns of the current conversation, in
    /// the shape a provider accepts. The persisted SwiftData conversation
    /// cannot serve this role — it carries no tool-call ids and maps command
    /// output onto the `system` role.
    let agentMessageHistory = ConversationMessageHistory()
    /// Last routed provider display name + routing source label, for the
    /// run status line. Set by resolveAgentProvider (both routed and
    /// fallback outcomes); never cleared so the last run stays visible.
    var lastRoutedProviderName: String?
    var lastRouteSource: String?
    /// AccessMode snapshot for the active run. The policy is built from
    /// this value at run start; mid-run changes apply to the next run.
    /// Nil when no run is active.
    var activeRunAccessMode: AgentMessage.AccessMode?

    private var currentTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let providerStore: AIProviderStore
    private let conversationStore: AIConversationStore
    let sanitizer = AIOutputSanitizer.self
    let executionManager: AgentExecutionManager
    /// The seam every provider is built through.
    ///
    /// Not private: the agent path lives in extensions on this type spread
    /// across files, and the resolver's whole purpose is to be substitutable.
    /// A direct `LLMProviderFactory.provider(...)` call in any of them
    /// bypasses the seam and makes the agent path untestable.
    let providerResolver: any LLMProviderResolving
    /// Builds the permission policy for a run.
    ///
    /// A factory, not an instance: the access mode is a setting the user can
    /// change while a chat is open, so it is read when a run starts rather
    /// than when the engine is created.
    ///
    /// It takes the host the run is against, because an authorization in
    /// Bonk is an authorization *of that machine*: the standing rules the
    /// user set up for one host must not decide anything on another.
    ///
    /// Both agent paths build their policy through this, so the same command
    /// is judged by the same rule on either path. They used not to be: the
    /// tool loop consulted the access mode and the plan path did not, so
    /// "read-only" was not read-only on the plan path.
    let permissionPolicyFactory: @Sendable (String?) -> any AgentPermissionPolicy

    // Plan approval state
    var currentPlan: AgentPlan?
    var planApprovalContinuation: CheckedContinuation<Bool, Never>?

    init(
        providerStore: AIProviderStore = .shared,
        conversationStore: AIConversationStore = .shared,
        executionManager: AgentExecutionManager = .shared,
        providerResolver: any LLMProviderResolving = DefaultLLMProviderResolver(),
        permissionPolicyFactory: @escaping @Sendable (String?) -> any AgentPermissionPolicy = { hostScope in
            DefaultAgentPermissionPolicy(
                accessMode: AgentEngine.accessMode,
                hostScope: hostScope
            )
        }
    ) {
        self.providerStore = providerStore
        self.conversationStore = conversationStore
        self.executionManager = executionManager
        self.providerResolver = providerResolver
        self.permissionPolicyFactory = permissionPolicyFactory
    }

    // MARK: - Provider Resolution

    func resolveProvider() -> (AIProviderConfig, String)? {
        let provider = activeProvider ?? providerStore.activeProvider
        guard let provider else {
            lastError = L.t(.noActiveProvider)
            return nil
        }
        let key = provider.apiKey
        guard !provider.type.needsAPIKey || !key.isEmpty else {
            lastError = String(format: L.t(.apiKeyNotSet), provider.name)
            return nil
        }
        activeProvider = provider
        return (provider, key)
    }

    /// Phase 1 agent provider resolution via ModelRouter. Deterministic core
    /// only (no decision engine yet): preferred active provider still wins
    /// whenever it survives the hard filters, so behavior matches
    /// resolveProvider in the common case. Router misses fall back to the
    /// legacy path — routing never fails a run the old code would start.
    /// Every outcome leaves a trace (router.selected / router.fallback).
    func resolveAgentProvider(task: IntelligenceTask, input: String) async -> (AIProviderConfig, String)? {
        let preferredID = activeProvider?.id ?? providerStore.activeProvider?.id
        let routerContext = RouterContext(
            task: task,
            contextSize: input.count,
            latencyBudgetMs: 15_000,
            requiresCapability: task == .agentExecute ? "toolCalls" : nil
        )
        let start = Date()
        let routed = ModelRouter.shared.routeDeterministic(
            task: task,
            providers: providerStore.providers,
            context: routerContext,
            preferredID: preferredID
        )
        let latencyMs = Date().timeIntervalSince(start) * 1000
        let taskLabel = task == .agentExecute ? "agentExecute" : "agentPlan"
        if let routed {
            let provider = routed.provider
            let key = provider.apiKey
            guard !provider.type.needsAPIKey || !key.isEmpty else {
                lastError = String(format: L.t(.apiKeyNotSet), provider.name)
                await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
                    kind: .routerFallback, engine: "router", task: taskLabel,
                    latencyMs: latencyMs, success: false, result: "fallback-missing-key"
                ))
                lastRoutedProviderName = provider.name
                lastRouteSource = "default"
                return resolveProvider()
            }
            activeProvider = provider
            lastRoutedProviderName = provider.name
            lastRouteSource = "\(routed.source)"
            await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
                kind: .routerSelected, engine: "router", task: taskLabel,
                latencyMs: latencyMs, result: "\(routed.source)"
            ))
            return (provider, key)
        }
        await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
            kind: .routerFallback, engine: "router", task: taskLabel,
            latencyMs: latencyMs, success: false, result: "fallback-no-route"
        ))
        let legacy = resolveProvider()
        lastRoutedProviderName = legacy?.0.name
        lastRouteSource = "default"
        return legacy
    }

    // MARK: - Unified Entry Point (snapshot-first)

    /// Execute with CommandContextSnapshot (Intelligence-owned, preferred).
    func execute(
        input: String,
        mode: AIMode,
        snapshot: CommandContextSnapshot,
        systemPromptOverride: String? = nil
    ) async -> String? {
        await execute(input: input, mode: mode, context: snapshot.asLegacyTerminalContext, systemPromptOverride: systemPromptOverride, snapshotForLog: snapshot)
    }

    /// Legacy entry point (TerminalContext) — delegates to snapshot path for parity.
    func execute(
        input: String,
        mode: AIMode,
        context: TerminalContext = TerminalContext(),
        systemPromptOverride: String? = nil
    ) async -> String? {
        let snapshot = CommandContextSnapshot(legacy: context)
        return await execute(input: input, mode: mode, context: context, systemPromptOverride: systemPromptOverride, snapshotForLog: snapshot)
    }

    private func execute(
        input: String,
        mode: AIMode,
        context: TerminalContext,
        systemPromptOverride: String?,
        snapshotForLog: CommandContextSnapshot
    ) async -> String? {
        isProcessing = true
        streamingResponse = ""
        lastError = nil
        currentExplanation = nil
        defer { isProcessing = false }

        guard let (provider, apiKey) = resolveProvider() else {
            return nil
        }

        let composed = SystemPromptComposer.compose(
            mode: mode, override: systemPromptOverride, context: context
        )
        let systemPrompt = composed.systemPrompt
        let untrustedContext = composed.untrustedContext
        let label = mode.rawValue

        // swiftlint:disable:next line_length
        Log.ai.info("\(label, privacy: .public): provider=\(provider.name, privacy: .public) model=\(provider.model, privacy: .public)")
        let llmProvider = providerResolver.provider(
            for: provider, apiKey: apiKey, workload: .chat
        )

        let maxRetries = 2
        for attempt in 0 ... maxRetries {
            // A failed stream may have emitted partial text before ending.
            // Do not concatenate that partial result into the next attempt.
            if attempt > 0 {
                streamingResponse = ""
            }
            do {
                // Remote state rides as its own user-role message so the
                // system prompt stays entirely app-authored. Ordering puts it
                // before the user's request: it is context for the request,
                // and a trailing untrusted block would be the last thing read
                // before the model answers.
                let response: String = if mode == .agent {
                    try await executeNonStreaming(
                        provider: llmProvider,
                        systemPrompt: systemPrompt,
                        userPrompt: input,
                        untrustedContext: untrustedContext
                    )
                } else {
                    try await executeStreaming(
                        provider: llmProvider,
                        systemPrompt: systemPrompt,
                        userPrompt: input,
                        untrustedContext: untrustedContext
                    )
                }

                let sanitized = sanitizer.sanitize(response)

                let finalResponse: String
                if !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalResponse = sanitized
                } else if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // swiftlint:disable:next line_length
                    Log.ai.warning("\(label, privacy: .public): empty response from \(provider.name, privacy: .public)")
                    throw AIError.emptyResponse
                }

                currentExplanation = finalResponse
                return finalResponse
            } catch {
                if Task.isCancelled {
                    return nil
                }

                // Don't retry non-retryable errors (auth failures, client errors)
                if let aiError = error as? AIError, !aiError.isRetryable {
                    lastError = error.localizedDescription
                    let errorMsg = error.localizedDescription
                    Log.ai.error(
                        "\(label, privacy: .public): non-retryable error: \(errorMsg, privacy: .public)"
                    )
                    return nil
                }

                if attempt < maxRetries {
                    Log.ai.warning(
                        "\(label, privacy: .public): attempt \(attempt + 1) failed, retrying"
                    )
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                } else {
                    lastError = error.localizedDescription
                    // swiftlint:disable:next line_length
                    Log.ai.error("\(label, privacy: .public): all attempts failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return nil
    }

    // MARK: - Streaming Execution (Ask/Edit)

    private func executeStreaming(
        provider: any LLMProvider,
        systemPrompt: String,
        userPrompt: String,
        untrustedContext: String? = nil,
        projectInstructions: String? = nil
    ) async throws -> String {
        var lastUIUpdate = Date.distantPast
        var result = ""
        let messages = Self.chatMessages(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            untrustedContext: untrustedContext,
            projectInstructions: projectInstructions
        )
        for try await event in provider.stream(
            messages: messages,
            maxTokens: nil,
            // Ask/Edit expects a direct command/explanation. Reasoning models
            // otherwise may spend the whole small output budget on hidden
            // reasoning and return no visible content.
            disableReasoning: true
        ) {
            switch event {
            case let .textDelta(delta):
                result += delta
                let now = Date()
                if now.timeIntervalSince(lastUIUpdate) > 0.05 {
                    streamingResponse = result
                    lastUIUpdate = now
                }
            case .reasoning, .toolCall, .usage, .completed:
                break
            }
        }
        streamingResponse = result
        return result
    }

    /// Read the skills the connected host offers.
    ///
    /// Read once, here, where the host is known, and handed to whichever
    /// path runs — the same shape as the project's instruction files.
    ///
    /// A host with no skills is the normal case and must not be an error:
    /// skills are an enhancement, never a precondition for running.
    func loadSkillListing(
        sshService: SSHNetworkService,
        hybridSession: TerminalSession?
    ) async -> String? {
        let summaries = await RemoteSkills.load(
            executor: { command in
                if let session = hybridSession {
                    return try await session.executeHybrid(command, registerHandle: nil)
                }
                return try await sshService.executeCommand(command)
            }
        )
        return RemoteSkills.listingMessage(for: summaries)
    }

    // MARK: - Non-Streaming Execution (Agent)

    /// This overload intentionally carries no untrusted context.
    ///
    /// Dropping remote data fails safe: the boundary is that remote bytes never
    /// reach the system role, and sending none satisfies it. Do not "restore
    /// consistency" by concatenating remote state into `systemPrompt` at a call
    /// site — that is the Finding 5 defect, and a test now fails if it happens.
    func executeNonStreaming(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String,
        projectInstructions: String? = nil
    ) async throws -> String {
        try await executeNonStreaming(
            provider: providerResolver.provider(
                for: provider, apiKey: apiKey, workload: .chat
            ),
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            projectInstructions: projectInstructions
        )
    }

    /// Read the project's instruction files from the connected host.
    ///
    /// The host's working directory is remote-controlled — it arrives in the
    /// OSC window title — so it is quoted and escaped by the loader, never
    /// interpolated raw. A missing instruction file is the normal case and
    /// must not be an error: instructions are an enhancement, never a
    /// precondition for running.
    func loadProjectInstructions(
        sshService: SSHNetworkService,
        hybridSession: TerminalSession?,
        cwd: String?
    ) async -> String? {
        let entries = await RemoteProjectInstructions.load(
            executor: { command in
                if let session = hybridSession {
                    return try await session.executeHybrid(command, registerHandle: nil)
                }
                return try await sshService.executeCommand(command)
            },
            cwd: cwd
        )
        return RemoteProjectInstructions.message(entries: entries)
    }

    private func executeNonStreaming(
        provider: any LLMProvider,
        systemPrompt: String,
        userPrompt: String,
        untrustedContext: String? = nil,
        projectInstructions: String? = nil
    ) async throws -> String {
        let response = try await provider.chat(
            messages: Self.chatMessages(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                untrustedContext: untrustedContext,
                projectInstructions: projectInstructions
            ),
            maxTokens: nil,
            disableReasoning: false
        )
        return response.text
    }

    /// Assemble the message list, keeping remote state out of the system role.
    ///
    /// One function builds the conversation for both streaming and
    /// non-streaming, so there is a single place where the trust boundary
    /// holds. If the untrusted block were folded into `userPrompt` the result
    /// would look identical to a model and lose the separation; as its own
    /// message the boundary is visible in the transcript and testable here.
    nonisolated static func chatMessages(
        systemPrompt: String,
        userPrompt: String,
        untrustedContext: String?,
        projectInstructions: String? = nil
    ) -> [LLMMessage] {
        var messages: [LLMMessage] = [.system(systemPrompt)]
        // The project's instructions come first: they are standing context
        // for the whole turn. Then the remote state, then the request — the
        // request is the last thing read.
        if let projectInstructions, !projectInstructions.isEmpty {
            messages.append(.user(projectInstructions))
        }
        if let untrustedContext, !untrustedContext.isEmpty {
            messages.append(.user(untrustedContext))
        }
        messages.append(.user(userPrompt))
        return messages
    }

    // MARK: - Agent Mode (Plan → Approve → Execute)

    // Implementation moved to AgentPlanExecutor.swift

    /// Drop the model's memory of the current conversation.
    ///
    /// The transcript the user reads and the memory the model holds are two
    /// different things, and both have to go for "new chat" to mean new
    /// chat — otherwise the model keeps answering from turns the user can no
    /// longer see.
    func resetAgentMemory() {
        agentMessageHistory.reset()
    }

    /// Append an agent message to in-memory list and optionally persist to SwiftData.
    func appendAgentMessage(
        _ role: AgentMessage.Role,
        content: String,
        thinking: String? = nil,
        command: String? = nil,
        status: AgentMessage.CommandStatus? = nil,
        duration: TimeInterval? = nil,
        errorCode: AgentErrorCode? = nil,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) {
        agentMessages.append(AgentMessage(
            role: role, content: content,
            command: command, thinking: thinking,
            status: status, duration: duration, errorCode: errorCode
        ))

        // Persist to SwiftData if conversation is available
        if let conversation, let context {
            let msgRole: AIMessageRecord.MessageRole = switch role {
            case .user: .user
            case .assistant: .assistant
            case .system, .commandOutput: .system
            }
            conversationStore.addMessage(
                to: conversation, role: msgRole, content: content,
                thinking: thinking, command: command, context: context
            )
        }
    }

    /// Terminal state as an untrusted block for a **user-role** message.
    ///
    /// Deliberately not a system-prompt string. `system` is the authority
    /// role, so remote bytes placed there speak with the product's voice; the
    /// fix is that they never reach that role, not that they are escaped
    /// inside it. Routing both snapshot shapes through one renderer means a new
    /// remote field has exactly one place to be added, and that place is not
    /// the system prompt.
    private func buildContextString(_ context: TerminalContext) -> String? {
        RemoteTerminalState(context: context).untrustedBlock()
    }

    private func buildContextString(_ snapshot: CommandContextSnapshot) -> String? {
        RemoteTerminalState(
            currentDirectory: snapshot.currentDirectory,
            shell: snapshot.shell,
            recentCommands: snapshot.recentCommands,
            recentOutput: snapshot.recentOutput
        ).untrustedBlock()
    }

    func buildAgentMessages() -> [[String: String]] {
        var messages: [[String: String]] = []
        for msg in agentMessages.suffix(20) {
            messages.append(contentsOf: msg.toAIMessages())
        }
        return messages
    }

    func requestConfirmation(command: String, riskLevel: PendingCommand.RiskLevel, reasonDetail: String = "") async -> Bool {
        await withCheckedContinuation { continuation in
            pendingConfirmation = PendingCommand(
                command: command,
                reason: riskLevel == .dangerous ? L.t(.dangerousCommand) : L.t(.moderate),
                riskLevel: riskLevel,
                reasonDetail: reasonDetail,
                continuation: { [weak self] confirmed in
                    self?.pendingConfirmation = nil
                    continuation.resume(returning: confirmed)
                }
            )
        }
    }

    // MARK: - Plan Approval

    func approvePlan() {
        planApprovalContinuation?.resume(returning: true)
        planApprovalContinuation = nil
        currentPlan = nil
    }

    func rejectPlan() {
        planApprovalContinuation?.resume(returning: false)
        planApprovalContinuation = nil
        currentPlan = nil
    }

    // MARK: - Cancel

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        activeRuntime?.cancel()
        activeRuntime = nil
        if let pending = pendingConfirmation {
            pending.continuation(false)
            pendingConfirmation = nil
        }
        planApprovalContinuation?.resume(returning: false)
        planApprovalContinuation = nil
        currentPlan = nil
        streamingResponse = ""
        currentExplanation = nil

        Task {
            await executionManager.cancelActive()
        }
    }

    /// Asynchronous cancellation with guaranteed completion of the escalation cycle.
    func cancelAsync() async {
        cancel()
        await executionManager.cancelActive()
    }

    // MARK: - Timeout Helper

    func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - System Prompt Composition

/// The two halves of an agent request, kept apart by type.
///
/// The split is structural on purpose. Handing callers a finished system string
/// and asking them not to append remote bytes to it is a convention; returning
/// `systemPrompt` and `untrustedContext` as separate fields means the only way
/// to get remote data into the authority role is to rebuild the string by hand,
/// which is visible in a diff.
struct ComposedAgentRequest: Sendable {
    /// App-authored: mode policy, optional override, and the fixed trust rule.
    /// Nothing here is derived from a `TerminalContext`.
    let systemPrompt: String
    /// Remote-derived. Rides as its own user-role message.
    let untrustedContext: String?
}

/// The single place a system prompt is composed.
///
/// Remote terminal state does not enter here. `system` is the authority role, so
/// any remote byte interpolated into it speaks in the product's voice — the
/// vulnerability itself, not a formatting detail. The prompt states the rule; the
/// data rides as a separate user-role message.
enum SystemPromptComposer {
    /// `@MainActor` because `RemoteTerminalState.init` is. The composition used
    /// to be inline in `execute`, which is main-actor isolated, so this carries
    /// the same context rather than introducing a new one.
    @MainActor
    static func compose(
        mode: AIMode,
        override: String?,
        context: TerminalContext
    ) -> ComposedAgentRequest {
        ComposedAgentRequest(
            // The system prompt is entirely app-authored. The project's own
            // instructions are not part of it: they are the project's
            // guidance, and they must not be able to authorize anything.
            //
            // The Ask path has no route to the host — two of its three entry
            // points are not attached to a terminal — so it carries no project
            // instructions. The agent path reads them from the host.
            systemPrompt: (override ?? mode.systemPrompt) + "\n\n" + RemoteTerminalState.trustPolicy,
            untrustedContext: RemoteTerminalState(context: context).untrustedBlock()
        )
    }
}

// MARK: - AIMode Extensions

extension AIMode {
    var systemPrompt: String {
        switch self {
        case .ask:
            """
            You are a concise technical assistant inside an SSH terminal client.

            Output rules (strict):
            - Answer directly. The first line is the answer, not an intro.
            - Terse. No greetings, no filler, no "Sure", no "I can help with that".
            - Commands go in fenced ```bash blocks, runnable as-is.
            - Inline code for paths, flags, and file names.
            - Short bullets only when they add value.
            - Match the user's language.
            - If context is insufficient, say exactly what you need and ask once.
            """
        case .agent:
            AgentPrompts.systemPrompt
        }
    }
}
