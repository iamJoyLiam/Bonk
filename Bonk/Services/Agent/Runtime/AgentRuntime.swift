//
//  AgentRuntime.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation
import os

/// Decoupled Agent Runtime driving the full Agentic Loop.
/// Emits an immutable `AsyncStream<AgentEvent>` for the UI to consume.
///
/// Phase 1: the runtime OWNS per-run AgentState and the sole
/// AgentBudgetController. Both are populated but never read to alter
/// execution — budget produces warnings (trace only), never enforcement.
final class AgentRuntime: @unchecked Sendable {
    let contextProvider: any AgentContextProvider
    let modelGateway: any AgentModelGateway
    let toolRegistry: AgentToolRegistry
    let permissionPolicy: any AgentPermissionPolicy
    let executionManager: AgentExecutionManager
    let transcriptStore: AgentTranscriptStore
    let maxIterations: Int
    /// Cross-run decision facts. Nil in tests/legacy paths — all recording
    /// sites skip silently when nil (zero behavior change).
    let decisionMemory: AgentDecisionMemory?
    /// Engine consulted for confirmation folding (Phase 2). Nil disables
    /// the gate entirely: every confirm shows the dialog (Phase 1 behavior).
    let foldEngine: (any DecisionEngine)?
    /// Engine consulted for semantic progress judgment (Phase 3, Tier 2).
    /// Nil disables Tier 2: only the guard and Tier-1 observation run,
    /// which never break the loop on their own.
    let progressEngine: (any DecisionEngine)?

    private let pendingApprovals = OSAllocatedUnfairLock<[String: CheckedContinuation<Bool, Never>]>(uncheckedState: [:])
    private let activeTask = OSAllocatedUnfairLock<Task<Void, Never>?>(uncheckedState: nil)
    private let ownedState = OSAllocatedUnfairLock(uncheckedState: AgentState())
    private let budget: OSAllocatedUnfairLock<AgentBudgetController>
    private let progressEvaluator = OSAllocatedUnfairLock(uncheckedState: ProgressEvaluator())
    private static let budgetLog = Logger(subsystem: "com.bonk", category: "AgentBudget")

    init(
        contextProvider: any AgentContextProvider = DefaultAgentContextProvider(),
        modelGateway: any AgentModelGateway,
        toolRegistry: AgentToolRegistry = AgentToolRegistry(),
        permissionPolicy: any AgentPermissionPolicy = DefaultAgentPermissionPolicy(),
        executionManager: AgentExecutionManager = .shared,
        transcriptStore: AgentTranscriptStore = AgentTranscriptStore(),
        maxIterations: Int = 25,
        decisionMemory: AgentDecisionMemory? = nil,
        foldEngine: (any DecisionEngine)? = nil,
        progressEngine: (any DecisionEngine)? = nil
    ) {
        self.contextProvider = contextProvider
        self.modelGateway = modelGateway
        self.toolRegistry = toolRegistry
        self.permissionPolicy = permissionPolicy
        self.executionManager = executionManager
        self.transcriptStore = transcriptStore
        self.maxIterations = maxIterations
        self.decisionMemory = decisionMemory
        self.foldEngine = foldEngine
        self.progressEngine = progressEngine
        self.budget = OSAllocatedUnfairLock(uncheckedState: AgentBudgetController(maxIterations: maxIterations))
    }

    /// Snapshot of the owned per-run state. Read-only for future consumers
    /// (DecisionEngine, UI); Phase 1 has no readers that alter execution.
    var currentState: AgentState {
        ownedState.withLock { $0 }
    }

    /// Resolves a pending user approval for a tool call.
    func resolvePermission(id: String, approved: Bool) {
        let continuation = pendingApprovals.withLock { $0.removeValue(forKey: id) }
        continuation?.resume(returning: approved)
    }

    /// Cancels active task and sends instant SIGINT via executionManager.
    func cancel(reason _: String = "User cancelled execution") {
        let approvals = pendingApprovals.withLock { state -> [CheckedContinuation<Bool, Never>] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for approval in approvals {
            approval.resume(returning: false)
        }
        Task {
            await executionManager.cancelActive()
        }
        activeTask.withLock { task in
            task?.cancel()
        }
    }

    /// Executes the agent loop and returns a stream of events.
    func run(
        input: String,
        executor: @escaping @Sendable (String, (@Sendable (any CommandExecutionHandle) -> Void)?) async throws -> (output: String, exitCode: Int32)
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.executeLoop(input: input, executor: executor, continuation: continuation)
                continuation.finish()
            }

            activeTask.withLock { $0 = task }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Core Agent Loop

    private func executeLoop(
        input: String,
        executor: @escaping @Sendable (String, (@Sendable (any CommandExecutionHandle) -> Void)?) async throws -> (output: String, exitCode: Int32),
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }

        emit(.userMessage(input))

        // Phase 1: own the per-run state from the first event. Population
        // only — nothing below reads it to alter execution.
        ownedState.withLock {
            $0.goal = input
            $0.appendObservation(AgentObservation(kind: .userMessage, text: input))
        }

        if Task.isCancelled {
            emit(.executionInterrupted(reason: "Task was cancelled prior to starting."))
            return
        }

        // 1. Context Assembly
        let envContext = await contextProvider.assembleContext(input: input)
        var basePrompt = AgentPrompts.toolSystemPrompt
        if !envContext.isEmpty {
            basePrompt += "\n\n## Environment Context\n\(envContext)"
        }
        let systemPrompt = CustomInstructions.buildSystemPrompt(base: basePrompt)

        var messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(input),
        ]

        let terminationGuard = TerminationGuard()
        // Consecutive tool failures (thrown error or non-zero exit), regardless of output
        // equality — catches loops whose output varies slightly each round.
        var consecutiveToolFailures = 0

        // 2. Iteration Loop
        iterationLoop: for iteration in 0 ..< maxIterations {
            if Task.isCancelled {
                emit(.executionInterrupted(reason: "Execution cancelled by user."))
                return
            }

            // Phase 1: budget counting + warnings (trace only, never enforced).
            // Counters mirror into the owned state so any exit path leaves
            // fresh numbers behind.
            let (iterationWarnings, budgetSnap) = budget.withLock { lock -> ([BudgetWarning], (iterations: Int, toolCalls: Int, decisionCalls: Int, wallClockMs: Double, inputTokens: Int, outputTokens: Int)) in
                let warnings = lock.recordIteration()
                return (warnings, lock.snapshot)
            }
            ownedState.withLock {
                $0.budget.iterationsUsed = budgetSnap.iterations
                $0.budget.wallClockMs = budgetSnap.wallClockMs
            }
            for warning in iterationWarnings {
                traceBudgetWarning(warning)
            }
            // Phase 5: hard budget halt. Enforcement only adds stops.
            if haltIfBudgetExceeded(continuation: continuation) {
                return
            }

            let response: LLMResponse
            do {
                response = try await modelGateway.chat(messages: messages, tools: toolRegistry.definitions)
            } catch {
                if Task.isCancelled {
                    emit(.executionInterrupted(reason: "Execution cancelled by user."))
                } else {
                    emit(.error(code: .modelFailure, message: "Model communication failed: \(error.localizedDescription)"))
                }
                return
            }

            // Phase 5: accumulate REPORTED usage (nil stays unknown, never
            // zero-filled), mirror into state, then enforce before spending
            // more. A single response can itself blow the budget.
            let usageWarnings = budget.withLock { $0.recordUsage(response.usage) }
            let usageSnap = budget.withLock { $0.snapshot }
            ownedState.withLock {
                $0.budget.inputTokens = usageSnap.inputTokens
                $0.budget.outputTokens = usageSnap.outputTokens
            }
            for warning in usageWarnings {
                traceBudgetWarning(warning)
            }
            if haltIfBudgetExceeded(continuation: continuation) {
                return
            }

            // Phase 5: compact stale history before it grows further.
            // Operates on messages only; AgentState is preserved, never
            // re-derived from the transcript. The UI note below is a
            // transcript fact only — events never enter LLM messages.
            if await maybeCompact(messages: &messages, lastUsage: response.usage) {
                emit(.contextCompacted)
            }

            // Yield assistant text if present
            if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emit(.assistantText(response.text))
            }

            // If model made no tool calls, it's done answering
            if response.toolCalls.isEmpty {
                emit(.completed)
                return
            }

            // Append assistant turn to message history
            messages.append(LLMMessage(
                role: .assistant,
                content: response.text,
                toolCalls: response.toolCalls
            ))

            // Execute each requested tool call
            for toolCall in response.toolCalls {
                switch await runToolCall(
                    toolCall,
                    iteration: iteration,
                    goal: input,
                    messages: &messages,
                    terminationGuard: terminationGuard,
                    consecutiveFailures: &consecutiveToolFailures,
                    executor: executor,
                    continuation: continuation
                ) {
                case .next:
                    continue
                case .breakLoop:
                    break iterationLoop
                case .denied:
                    emit(.completed)
                    return
                case .halt:
                    return
                }
            }
        }

        // Loop reached max iterations: ask for final synthesis
        emit(.assistantText(L.t(.agMaxRoundsReached)))
        messages.append(.user("All terminal inspection commands have been completed. Please provide your final conclusion and answer the original request: '\(input)'. Do not call any tools."))
        if let finalTurn = try? await modelGateway.chat(messages: messages, tools: []) {
            let answer = finalTurn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                emit(.assistantText(answer))
            }
        }
        emit(.completed)
    }

    /// Outcome of a single tool call step inside the iteration loop.
    private enum ToolStepOutcome {
        case next
        case breakLoop
        case denied
        case halt
    }

    /// Executes one tool call: permission gate, execution, output guard, and termination
    /// evaluation. Returns whether the loop should continue, break to final synthesis, or halt.
    /// Executor closure type for running shell commands on the agent target.
    private typealias ToolExecutorFn = @Sendable (
        String,
        (@Sendable (any CommandExecutionHandle) -> Void)?
    ) async throws -> (output: String, exitCode: Int32)

    /// Hard stop after this many consecutive tool failures, even when outputs differ.
    private static let maxConsecutiveToolFailures = 5

    private func runToolCall(
        _ toolCall: LLMToolCall,
        iteration: Int,
        goal: String,
        messages: inout [LLMMessage],
        terminationGuard: TerminationGuard,
        consecutiveFailures: inout Int,
        executor: ToolExecutorFn,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> ToolStepOutcome {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }

        if Task.isCancelled {
            emit(.executionInterrupted(reason: "Execution cancelled by user."))
            return .halt
        }

        let callId = toolCall.id
        emit(.toolCallStarted(id: callId, tool: toolCall.name, input: toolCall.argumentsJSON))

        let authorized: AuthorizedToolCall
        switch await authorizeToolCall(toolCall, iteration: iteration, messages: &messages, continuation: continuation) {
        case let .authorized(toolCall):
            authorized = toolCall
        case .skipped:
            return .next
        case .denied:
            return .denied
        }

        // Execute tool
        let startTime = Date()
        let output: String
        let exitCode: Int32
        do {
            let execResult = try await authorized.tool.execute(
                id: callId,
                arguments: authorized.args,
                executionManager: executionManager,
                executor: executor
            )
            output = execResult.output
            exitCode = execResult.exitCode
        } catch {
            if Task.isCancelled {
                emit(.executionInterrupted(reason: "Execution cancelled."))
                return .halt
            }
            output = "Execution failed: \(error.localizedDescription)"
            exitCode = 1
        }
        if !Task.isCancelled {
            await executionManager.clearActive()
        }

        let duration = Date().timeIntervalSince(startTime)
        let guardedOutput = OutputGuard.guardOutput(output).content
        emit(.toolOutput(id: callId, output: guardedOutput))
        emit(.toolCompleted(id: callId, exitCode: exitCode, duration: duration))

        // Phase 1: populate owned state (never read back for decisions yet).
        let stepKey = Self.stateKey(tool: toolCall.name, arguments: authorized.args)
        let toolSnap = budget.withLock { lock -> (iterations: Int, toolCalls: Int, decisionCalls: Int, wallClockMs: Double, inputTokens: Int, outputTokens: Int) in
            lock.recordToolCall()
            return lock.snapshot
        }
        ownedState.withLock {
            $0.appendStep(AgentStepState(
                tool: toolCall.name,
                normalizedKey: stepKey,
                exitCode: exitCode,
                outputSummary: String(guardedOutput.prefix(200))
            ))
            $0.appendObservation(AgentObservation(kind: .toolOutput, text: guardedOutput))
            $0.budget.toolCalls = toolSnap.toolCalls
            $0.budget.wallClockMs = toolSnap.wallClockMs
        }

        let call = ExecutedCall(
            name: toolCall.name,
            rawArgs: toolCall.argumentsJSON,
            output: guardedOutput,
            callId: callId,
            normalizedKey: stepKey
        )
        return await evaluateStep(
            call,
            exitCode: exitCode,
            goal: goal,
            iteration: iteration,
            failures: &consecutiveFailures,
            terminationGuard: terminationGuard,
            messages: &messages,
            continuation: continuation
        )
    }

    /// State key for one tool call: normalized command for run_command,
    /// tool + normalized arguments otherwise. Facts only, no raw secrets
    /// beyond what the caller already placed in arguments.
    private static func stateKey(tool: String, arguments: [String: String]) -> String {
        if tool == "run_command", let cmd = arguments["command"] {
            return CommandNormalizer.normalizedKey(cmd)
        }
        let argsKey = arguments.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(CommandNormalizer.normalizedKey($0.value))" }
            .joined(separator: " ")
        return argsKey.isEmpty ? tool : "\(tool) \(argsKey)"
    }

    /// Fire-and-forget budget warning: trace + log, never enforcement.
    private func traceBudgetWarning(_ warning: BudgetWarning) {
        let result: String
        switch warning {
        case let .iterationsHigh(used, max): result = "iterations-\(used)/\(max)"
        case let .wallClockHigh(elapsedMs, maxMs): result = "wallclock-\(Int(elapsedMs))/\(Int(maxMs))ms"
        case let .decisionCallsHigh(used, max): result = "decision-calls-\(used)/\(max)"
        case let .inputTokensHigh(used, max): result = "input-tokens-\(used)/\(max)"
        case let .outputTokensHigh(used, max): result = "output-tokens-\(used)/\(max)"
        }
        Self.budgetLog.warning("\(result, privacy: .public)")
        traceAgent(kind: .budgetWarning, engine: "budget", task: "agentExecute", result: result)
    }

    /// Phase 5 hard halt. Emits, traces, and stops the run WITHOUT final
    /// synthesis (synthesis itself spends tokens). Only ever adds stops.
    /// Returns true when the run must halt now.
    private func haltIfBudgetExceeded(
        continuation: AsyncStream<AgentEvent>.Continuation
    ) -> Bool {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }
        guard let reason = budget.withLock({ $0.exceededReason() }) else { return false }
        emit(.error(code: .budgetExceeded, message: "Agent budget exceeded (\(reason.rawValue)). Stopping to bound cost and latency."))
        traceAgent(kind: .budgetExceeded, engine: "budget", task: "agentExecute", result: reason.rawValue)
        return true
    }

    // Driving-task-only compaction count. Mutated exclusively by the task
    // running executeLoop (Runtime is @unchecked Sendable; this follows the
    // same single-driver discipline as the loop itself).
    private var compactionsPerformed = 0
    private static let maxCompactionsPerRun = 5
    /// Input-token level that triggers compaction. Heuristic pending
    /// per-model calibration; compared against reported usage first,
    /// labeled estimates only when the provider reports nothing.
    private static let compactAtInputTokens = 60_000
    private static let staleToolOutputKeepChars = 200
    private static let compactionMarker = "[…compacted]"

    /// Phase 5 context compaction. Two steps, both provider-safe:
    /// 1. Shrink stale tool outputs in place (message structure never
    ///    changes, so no orphaned tool references can occur). Idempotent.
    /// 2. If still over budget AND a user-role boundary exists, summarize
    ///    the middle into one user message. The suffix always starts at a
    ///    user message, so kept tool messages keep their assistant turn.
    /// AgentState is preserved throughout, never re-derived. Summary
    /// failures skip silently — compaction never loses history.
    private func maybeCompact(messages: inout [LLMMessage], lastUsage: TokenUsage?) async -> Bool {
        var compacted = false
        if messages.count > 7 {
            var shrunk = 0
            for index in 1 ..< (messages.count - 6) {
                guard messages[index].role == .tool else { continue }
                let content = messages[index].content
                guard !content.hasSuffix(Self.compactionMarker),
                      content.count > Self.staleToolOutputKeepChars
                else { continue }
                messages[index] = LLMMessage(
                    role: .tool,
                    content: String(content.prefix(Self.staleToolOutputKeepChars)) + Self.compactionMarker,
                    toolCallID: messages[index].toolCallID
                )
                shrunk += 1
            }
            if shrunk > 0 {
                compacted = true
                traceAgent(kind: .compactionPerformed, engine: "runtime", task: "agentExecute", result: "shrink-\(shrunk)")
            }
        }

        let overBudget: Bool
        if let input = lastUsage?.inputTokens {
            overBudget = input >= Self.compactAtInputTokens
        } else {
            // Estimate is a hint only — never budget truth (see TokenEstimator).
            overBudget = TokenEstimator.estimatedInputTokens(for: messages) >= Self.compactAtInputTokens
        }
        guard overBudget, compactionsPerformed < Self.maxCompactionsPerRun else { return compacted }
        // Cut at the most recent assistant or user message past the input.
        // Tool pairs are always adjacent (assistant-with-calls immediately
        // followed by its tool messages), so starting the suffix at an
        // assistant or user boundary can never orphan a kept tool message
        // from its assistant turn.
        let boundaryIndices = messages.indices.filter {
            $0 > 1 && (messages[$0].role == .assistant || messages[$0].role == .user)
        }
        guard let cut = boundaryIndices.max(),
              cut < messages.count - 1
        else { return compacted }

        var transcript = messages[1 ..< cut]
            .map { "\($0.role): \($0.content.prefix(500))" }
            .joined(separator: "\n")
        if transcript.count > 20_000 {
            transcript = String(transcript.prefix(20_000))
        }
        let summaryRequest = [
            LLMMessage.system("Summarize this agent working history into a compact brief for continued execution. Preserve: original goal, completed steps with outcomes, failures and error patterns, current hypotheses. Omit raw command outputs. Keep under 300 words."),
            LLMMessage.user(transcript),
        ]
        guard let summary = try? await modelGateway.chat(messages: summaryRequest, tools: []) else { return compacted }
        let text = summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return compacted }
        let summaryWarnings = budget.withLock { $0.recordUsage(summary.usage) }
        for warning in summaryWarnings {
            traceBudgetWarning(warning)
        }
        let before = messages.count
        messages = [messages[0], LLMMessage.user("Earlier context (compacted):\n" + text)] + Array(messages[cut...])
        compactionsPerformed += 1
        traceAgent(kind: .compactionPerformed, engine: "runtime", task: "agentExecute", result: "summary-\(before)->\(messages.count)")
        return true
    }

    /// A tool call that passed the permission gate and registry lookup.
    private struct AuthorizedToolCall {
        let tool: any AgentTool
        let args: [String: String]
    }

    /// Authorization result for one tool call.
    private enum ToolAuthorization {
        case authorized(AuthorizedToolCall)
        case skipped
        case denied
    }

    /// Runs the permission gate and registry lookup. Denials append a message and skip.
    /// Phase 2: a confirmRequired verdict first passes deterministic fold
    /// eligibility; only eligible commands meet the fold gate, and only a
    /// fold verdict skips the dialog. Everything else is unchanged.
    private func authorizeToolCall(
        _ toolCall: LLMToolCall,
        iteration: Int,
        messages: inout [LLMMessage],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> ToolAuthorization {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }

        let callId = toolCall.id
        let argsDict = toolCall.arguments.compactMapValues { "\($0)" }
        // Phase 1: record that a confirm gate was evaluated (facts only).
        // Memory is nil in tests/legacy paths — recording is skipped then.
        let memoryKey = Self.stateKey(tool: toolCall.name, arguments: argsDict)
        switch permissionPolicy.evaluate(tool: toolCall.name, arguments: argsDict) {
        case .allowed:
            break
        case let .confirmRequired(level, description):
            // Reason facts are read once and shared by the dialog and the
            // fold attempt below. Recording happens once per evaluation.
            let safetyLabel: String
            if toolCall.name == "run_command", let cmd = argsDict["command"] {
                safetyLabel = "L\(CommandSafety.classifyLevel(cmd).rawValue)"
            } else {
                safetyLabel = toolCall.name
            }
            let history = await decisionMemory?.facts(for: memoryKey)
            if let memory = decisionMemory {
                Task { await memory.recordEvaluation(key: memoryKey) }
            }
            let reason = ConfirmationReason.describe(safetyLevel: safetyLabel, history: history)
            // Phase 2 fold path: eligibility (deterministic) → gate (engine)
            // → fold skips the dialog. Any miss falls through to the dialog.
            if await tryFoldConfirmation(
                toolCall: toolCall, args: argsDict, iteration: iteration,
                history: history,
                callId: callId,
                continuation: continuation
            ) {
                break
            }
            emit(.permissionRequested(id: callId, description: description, level: level, reason: reason))
            let approved = await withCheckedContinuation { cont in
                pendingApprovals.withLock { $0[callId] = cont }
            }
            emit(.permissionResolved(id: callId, approved: approved))
            if let memory = decisionMemory {
                Task { await memory.recordDecision(key: memoryKey, decision: approved ? .approved : .denied) }
            }
            if !approved {
                emit(.executionInterrupted(reason: L.t(.agExecutionCancelled)))
                emit(.completed)
                return .denied
            }
        case let .blocked(reason):
            emit(.error(code: .generic, message: "Action blocked: \(reason)"))
            let content = "Blocked by safety policy: \(reason)"
            messages.append(LLMMessage(role: .tool, content: content, toolCallID: callId))
            return .skipped
        }
        guard let tool = toolRegistry.tool(named: toolCall.name) else {
            let errMsg = "Tool not found in registry: \(toolCall.name)"
            emit(.error(code: .generic, message: errMsg))
            let message = LLMMessage(role: .tool, content: errMsg, toolCallID: callId)
            messages.append(message)
            return .skipped
        }
        return .authorized(AuthorizedToolCall(tool: tool, args: argsDict))
    }

    /// Phase 2 confirmation folding. Returns true when the dialog was
    /// folded (auto-approved with full trace). Returns false for every
    /// other outcome — including engine errors — so the caller always
    /// falls back to the confirmation dialog. Never fails open.
    ///
    /// Folded approvals are deliberately NOT recorded in decision memory:
    /// only explicit user verdicts train future eligibility, otherwise
    /// folding would self-reinforce.
    private func tryFoldConfirmation(
        toolCall: LLMToolCall,
        args: [String: String],
        iteration: Int,
        history: CommandDecisionFacts?,
        callId: String,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> Bool {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }
        guard let engine = foldEngine else { return false }
        guard toolCall.name == "run_command", let cmd = args["command"] else { return false }
        // Eligibility first (deterministic): only .confirmRequired verdicts
        // with foldable effects and explicit prior approval meet the gate.
        // L3/L4, unsafe effects, and unseen/denied commands keep the dialog.
        let safetyLevel = CommandSafety.classifyLevel(cmd)
        let profile = CommandEffectProfiler.profile(command: cmd)
        let eligibility = ConfirmationFoldEvaluator.check(
            tool: toolCall.name, level: safetyLevel, effect: profile, facts: history
        )
        guard eligibility.eligible else { return false }

        let tagList = profile.tags.map(\.rawValue).sorted().joined(separator: "+")
        traceAgent(
            kind: .confirmationFoldable, engine: engine.engineName,
            result: "eligible-L\(safetyLevel.rawValue)-\(tagList)-approved×\(history?.allowCount ?? 0)"
        )
        let accessMode = (permissionPolicy as? DefaultAgentPermissionPolicy)?.accessMode.rawValue ?? "unknown"
        let (disposition, _) = await ConfirmationFoldGate.evaluate(
            engine: engine,
            facts: FoldGateFacts(
                tool: toolCall.name,
                normalizedCommand: CommandNormalizer.normalizedKey(cmd),
                safetyLevel: "L\(safetyLevel.rawValue)",
                accessMode: accessMode,
                semanticTags: tagList,
                previousUserDecision: "approved",
                sameCommandOccurrences: history?.occurrences ?? 0,
                iteration: iteration
            ),
            threshold: DecisionEngineConfig.load().decisionThreshold,
            task: "agentExecute"
        )
        let decisionWarnings = budget.withLock { $0.recordDecisionCall() }
        for warning in decisionWarnings {
            traceBudgetWarning(warning)
        }
        guard disposition == .foldConfirmation else { return false }
        // Folded (not allowed): the transcript records a fold fact with the
        // deterministic level and deciding engine — visibly distinct from a
        // manual approval, which stays on permissionRequested/Resolved.
        emit(.permissionFolded(
            id: callId, command: cmd,
            level: "L\(safetyLevel.rawValue)", engine: engine.engineName
        ))
        return true
    }

    /// Fire-and-forget agent trace. Never awaited on a hot path.
    private func traceAgent(
        kind: AgentTraceKind,
        engine: String,
        task: String = "agentExecute",
        latencyMs: Double = 0,
        success: Bool = true,
        result: String = ""
    ) {
        Task {
            await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
                kind: kind, engine: engine, task: task,
                latencyMs: latencyMs, success: success, result: result
            ))
        }
    }
    /// One executed tool call, ready for termination evaluation.
    private struct ExecutedCall {
        let name: String
        let rawArgs: String
        let output: String
        let callId: String
        let normalizedKey: String
    }

    /// Applies the consecutive-failure hard stop and the repetition guard.
    /// Returns whether the loop should continue or break to final synthesis.
    /// Phase 3: after a non-terminal guard outcome, the semantic progress
    /// evaluator may additionally break the loop on stalled progress. The
    /// guard stays authoritative for exact repeats and failures.
    private func evaluateStep(
        _ call: ExecutedCall,
        exitCode: Int32,
        goal: String,
        iteration: Int,
        failures: inout Int,
        terminationGuard: TerminationGuard,
        messages: inout [LLMMessage],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> ToolStepOutcome {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }
        if exitCode == 0 {
            failures = 0
        } else {
            failures += 1
            if failures >= Self.maxConsecutiveToolFailures {
                let stopNote = "Tool execution failed \(failures) times in a row. "
                    + "Stopping to avoid an endless loop."
                emit(.error(code: .generic, message: stopNote))
                let content = "\(call.output)\n\n[\(stopNote)]"
                messages.append(LLMMessage(role: .tool, content: content, toolCallID: call.callId))
                return .breakLoop
            }
        }
        let result = await terminationGuard.recordAndEvaluate(
            toolName: call.name,
            arguments: call.rawArgs,
            output: call.output
        )
        switch result {
        case .proceed:
            let message = LLMMessage(role: .tool, content: call.output, toolCallID: call.callId)
            messages.append(message)
        case let .warnDuplicate(dupTool):
            emit(.thinking("Warning: duplicate invocation of \(dupTool)"))
            let content = call.output + "\n\n[Warning: Duplicate tool execution without new findings.]"
            messages.append(LLMMessage(role: .tool, content: content, toolCallID: call.callId))
        case let .terminateLoop(reason):
            emit(.error(code: .generic, message: "Agent loop stopped: \(reason)"))
            let content = call.output + "\n\n[Warning: Repetitive tool calls detected. \(reason)]"
            messages.append(LLMMessage(role: .tool, content: content, toolCallID: call.callId))
            return .breakLoop
        }
        // Phase 3: non-terminal guard outcome — consult semantic progress.
        if await considerProgressBreak(
            call, exitCode: exitCode, goal: goal, iteration: iteration,
            messages: &messages, continuation: continuation
        ) {
            return .breakLoop
        }
        return .next
    }

    /// Phase 3 semantic progress check. Tier 1 runs for every non-terminal
    /// step; Tier 2 (engine score) runs only inside the suspicious window.
    /// Returns true when the loop should break on stalled progress.
    /// Nil engine, engine errors, and healthy scores all continue —
    /// this path never fails open into a break.
    private func considerProgressBreak(
        _ call: ExecutedCall,
        exitCode: Int32,
        goal: String,
        iteration: Int,
        messages: inout [LLMMessage],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> Bool {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }
        guard let engine = progressEngine else { return false }
        let assessment = progressEvaluator.withLock {
            $0.observe(
                callId: call.callId, tool: call.name, actionKey: call.normalizedKey,
                exitCode: exitCode, output: call.output, goal: goal, iteration: iteration
            )
        }
        guard case let .needsJudgment(option, context) = assessment else { return false }
        traceAgent(kind: .decisionRequested, engine: engine.engineName, task: "agentExecute", result: "progress-score")
        do {
            let start = Date()
            let judged = try await engine.score(option: option, context: context)
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let decisionWarnings = budget.withLock { $0.recordDecisionCall() }
            for warning in decisionWarnings {
                traceBudgetWarning(warning)
            }
            let verdict = progressEvaluator.withLock { $0.recordJudgment(score: judged.score) }
            guard case let .breakLoop(reason) = verdict else {
                traceAgent(kind: .decisionResolved, engine: engine.engineName, task: "agentExecute", latencyMs: latencyMs, result: "progress-continue")
                return false
            }
            traceAgent(kind: .decisionResolved, engine: engine.engineName, task: "agentExecute", latencyMs: latencyMs, result: "progress-break")
            emit(.error(code: .progressStall, message: "Agent loop stopped: \(reason)"))
            let content = call.output + "\n\n[Warning: No meaningful progress detected. \(reason)]"
            messages.append(LLMMessage(role: .tool, content: content, toolCallID: call.callId))
            return true
        } catch {
            traceAgent(kind: .decisionFallback, engine: engine.engineName, task: "agentExecute", success: false, result: "score-error")
            return false
        }
    }
}
