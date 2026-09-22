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
final class AgentRuntime: @unchecked Sendable {
    let contextProvider: any AgentContextProvider
    let modelGateway: any AgentModelGateway
    let toolRegistry: AgentToolRegistry
    let permissionPolicy: any AgentPermissionPolicy
    let executionManager: AgentExecutionManager
    let transcriptStore: AgentTranscriptStore
    let maxIterations: Int

    private let pendingApprovals = OSAllocatedUnfairLock<[String: CheckedContinuation<Bool, Never>]>(uncheckedState: [:])
    private let activeTask = OSAllocatedUnfairLock<Task<Void, Never>?>(uncheckedState: nil)

    init(
        contextProvider: any AgentContextProvider = DefaultAgentContextProvider(),
        modelGateway: any AgentModelGateway,
        toolRegistry: AgentToolRegistry = AgentToolRegistry(),
        permissionPolicy: any AgentPermissionPolicy = DefaultAgentPermissionPolicy(),
        executionManager: AgentExecutionManager = .shared,
        transcriptStore: AgentTranscriptStore = AgentTranscriptStore(),
        maxIterations: Int = 25
    ) {
        self.contextProvider = contextProvider
        self.modelGateway = modelGateway
        self.toolRegistry = toolRegistry
        self.permissionPolicy = permissionPolicy
        self.executionManager = executionManager
        self.transcriptStore = transcriptStore
        self.maxIterations = maxIterations
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
        iterationLoop: for _ in 0 ..< maxIterations {
            if Task.isCancelled {
                emit(.executionInterrupted(reason: "Execution cancelled by user."))
                return
            }

            let response: LLMResponse
            do {
                response = try await modelGateway.chat(messages: messages, tools: toolRegistry.definitions)
            } catch {
                if Task.isCancelled {
                    emit(.executionInterrupted(reason: "Execution cancelled by user."))
                } else {
                    emit(.error("Model communication failed: \(error.localizedDescription)"))
                }
                return
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
        switch await authorizeToolCall(toolCall, messages: &messages, continuation: continuation) {
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

        let call = ExecutedCall(
            name: toolCall.name,
            rawArgs: toolCall.argumentsJSON,
            output: guardedOutput,
            callId: callId
        )
        return await evaluateStep(
            call,
            exitCode: exitCode,
            failures: &consecutiveFailures,
            terminationGuard: terminationGuard,
            messages: &messages,
            continuation: continuation
        )
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
    private func authorizeToolCall(
        _ toolCall: LLMToolCall,
        messages: inout [LLMMessage],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> ToolAuthorization {
        func emit(_ event: AgentEvent) {
            transcriptStore.append(event)
            continuation.yield(event)
        }

        let callId = toolCall.id
        let argsDict = toolCall.arguments.compactMapValues { "\($0)" }
        switch permissionPolicy.evaluate(tool: toolCall.name, arguments: argsDict) {
        case .allowed:
            break
        case let .confirmRequired(level, description):
            emit(.permissionRequested(id: callId, description: description, level: level))
            let approved = await withCheckedContinuation { cont in
                pendingApprovals.withLock { $0[callId] = cont }
            }
            emit(.permissionResolved(id: callId, approved: approved))
            if !approved {
                emit(.executionInterrupted(reason: L.t(.agExecutionCancelled)))
                emit(.completed)
                return .denied
            }
        case let .blocked(reason):
            emit(.error("Action blocked: \(reason)"))
            let content = "Blocked by safety policy: \(reason)"
            messages.append(LLMMessage(role: .tool, content: content, toolCallID: callId))
            return .skipped
        }
        guard let tool = toolRegistry.tool(named: toolCall.name) else {
            let errMsg = "Tool not found in registry: \(toolCall.name)"
            emit(.error(errMsg))
            let message = LLMMessage(role: .tool, content: errMsg, toolCallID: callId)
            messages.append(message)
            return .skipped
        }
        return .authorized(AuthorizedToolCall(tool: tool, args: argsDict))
    }

    /// One executed tool call, ready for termination evaluation.
    private struct ExecutedCall {
        let name: String
        let rawArgs: String
        let output: String
        let callId: String
    }

    /// Applies the consecutive-failure hard stop and the repetition guard.
    /// Returns whether the loop should continue or break to final synthesis.
    private func evaluateStep(
        _ call: ExecutedCall,
        exitCode: Int32,
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
                emit(.error(stopNote))
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
            emit(.error("Agent loop stopped: \(reason)"))
            let content = call.output + "\n\n[Warning: Repetitive tool calls detected. \(reason)]"
            messages.append(LLMMessage(role: .tool, content: content, toolCallID: call.callId))
            return .breakLoop
        }
        return .next
    }
}
