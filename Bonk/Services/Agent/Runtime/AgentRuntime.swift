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
    func cancel(reason: String = "User cancelled execution") {
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
            .user(input)
        ]

        let terminationGuard = TerminationGuard()

        // 2. Iteration Loop
        for _ in 0 ..< maxIterations {
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
                if Task.isCancelled {
                    emit(.executionInterrupted(reason: "Execution cancelled by user."))
                    return
                }

                let callId = toolCall.id
                let toolName = toolCall.name
                let rawArgs = toolCall.argumentsJSON

                emit(.toolCallStarted(id: callId, tool: toolName, input: rawArgs))

                // Parse string dictionary from arguments
                let argsDict = toolCall.arguments.compactMapValues { "\($0)" }

                // Permission Gate
                let decision = permissionPolicy.evaluate(tool: toolName, arguments: argsDict)
                switch decision {
                case .allowed:
                    break

                case let .confirmRequired(level, description):
                    emit(.permissionRequested(id: callId, description: description, level: level))
                    let approved = await withCheckedContinuation { cont in
                        pendingApprovals.withLock { $0[callId] = cont }
                    }
                    emit(.permissionResolved(id: callId, approved: approved))
                    if !approved {
                        emit(.executionInterrupted(reason: "用户取消了命令执行。"))
                        emit(.completed)
                        return
                    }

                case let .blocked(reason):
                    emit(.error("Action blocked: \(reason)"))
                    messages.append(LLMMessage(
                        role: .tool,
                        content: "Blocked by safety policy: \(reason)",
                        toolCallID: callId
                    ))
                    continue
                }

                // Look up registered tool
                guard let tool = toolRegistry.tool(named: toolName) else {
                    let errMsg = "Tool not found in registry: \(toolName)"
                    emit(.error(errMsg))
                    messages.append(LLMMessage(role: .tool, content: errMsg, toolCallID: callId))
                    continue
                }

                // Execute tool
                let startTime = Date()
                let output: String
                let exitCode: Int32

                do {
                    let execResult = try await tool.execute(
                        id: callId,
                        arguments: argsDict,
                        executionManager: executionManager,
                        executor: executor
                    )
                    output = execResult.output
                    exitCode = execResult.exitCode
                } catch {
                    if Task.isCancelled {
                        emit(.executionInterrupted(reason: "Execution cancelled."))
                        return
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

                // Check termination guard (repetition detection)
                let guardResult = await terminationGuard.recordAndEvaluate(toolName: toolName, arguments: rawArgs, output: guardedOutput)
                switch guardResult {
                case .proceed:
                    messages.append(LLMMessage(
                        role: .tool,
                        content: guardedOutput,
                        toolCallID: callId
                    ))

                case let .warnDuplicate(dupTool):
                    emit(.thinking("Warning: duplicate invocation of \(dupTool)"))
                    messages.append(LLMMessage(
                        role: .tool,
                        content: "\(guardedOutput)\n\n[Warning: Duplicate tool execution without new findings.]",
                        toolCallID: callId
                    ))

                case let .terminateLoop(reason):
                    emit(.error("Agent loop stopped: \(reason)"))
                    messages.append(LLMMessage(
                        role: .tool,
                        content: "\(guardedOutput)\n\n[Warning: Repetitive tool calls detected. \(reason)]",
                        toolCallID: callId
                    ))
                }
            }
        }

        // Loop reached max iterations: ask for final synthesis
        emit(.assistantText("已达到最大执行轮次，正在总结最终结论..."))
        messages.append(.user("All terminal inspection commands have been completed. Please provide your final conclusion and answer the original request: '\(input)'. Do not call any tools."))
        if let finalTurn = try? await modelGateway.chat(messages: messages, tools: []) {
            let answer = finalTurn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                emit(.assistantText(answer))
            }
        }
        emit(.completed)
    }
}
