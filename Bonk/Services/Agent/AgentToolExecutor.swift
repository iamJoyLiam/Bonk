import Foundation
import SwiftData

/// Bundle of long-lived state for one tool-loop run. Keeps helper signatures
/// small instead of threading five parameters through every call.
private struct AgentToolContext {
    let llmProvider: any LLMProvider
    let sshService: SSHNetworkService
    let hybridExec: (@Sendable (String) async throws -> String)? // v3.3 — multiplexed channel when available
    let hostName: String?
    let conversation: AIConversationRecord?
    let context: ModelContext?
}

/// Real agentic loop: the model calls `run_command`, the engine executes on
/// the SSH session (safety-classified, user-confirmed when risky), output feeds
/// back into the conversation, and the loop repeats until the model answers.
extension AgentEngine {
    // MARK: - Tool-Calling Agent Loop (OpenAI-compatible providers)

    func runAgentToolLoop(
        input: String,
        sshService: SSHNetworkService,
        hostName: String?,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async {
        await runAgentToolLoop(input: input, sshService: sshService, hybridSession: nil, hostName: hostName, conversation: conversation, context: context)
    }

    /// v3.3 Hybrid overload — when a TerminalSession with vnextSession is available,
    /// exec reuses the multiplexed channel (Native 1000× channel vs 1000× Process).
    func runAgentToolLoop(
        input: String,
        sshService: SSHNetworkService,
        hybridSession: TerminalSession?,
        hostName: String?,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async {
        guard let (provider, apiKey) = resolveProvider() else { return }
        let llmProvider = LLMProviderFactory.provider(
            for: provider, apiKey: apiKey, workload: .agentToolLoop
        )
        let hybridExec: (@Sendable (String) async throws -> String)? = if let session = hybridSession {
            { @Sendable command async throws -> String in try await session.executeHybrid(command) }
        } else { nil }
        let toolContext = AgentToolContext(
            llmProvider: llmProvider,
            sshService: sshService, hybridExec: hybridExec, hostName: hostName,
            conversation: conversation, context: context
        )

        let systemPrompt = CustomInstructions.buildSystemPrompt(base: AgentPrompts.toolSystemPrompt)
        var messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(input),
        ]

        let maxIterations = AgentEngine.maxAgentIterations
        let terminationGuard = TerminationGuard()
        for iteration in 0 ..< maxIterations {
            guard !Task.isCancelled else { break }
            let result = await runToolIteration(
                iteration: iteration, input: input,
                toolContext: toolContext, messages: messages,
                terminationGuard: terminationGuard
            )
            messages = result.messages
            if result.finished {
                // If loop finished and last message wasn't an assistant answer, request final synthesis
                let lastMessageIsAssistant = messages.last?.role == .assistant && !(messages.last?.content.isEmpty ?? true)
                if !lastMessageIsAssistant {
                    let finalPrompt = "Based on all command outputs above, please provide your final conclusion and answer the user's original request: '\(input)'. Do not call any tools."
                    messages.append(.user(finalPrompt))
                    if let finalTurn = try? await toolContext.llmProvider.chat(
                        messages: messages, maxTokens: 2048, disableReasoning: false
                    ) {
                        let answer = finalTurn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !answer.isEmpty {
                            appendAgentMessage(
                                .assistant, content: answer,
                                conversation: toolContext.conversation, context: toolContext.context
                            )
                        }
                    }
                }
                return
            }
        }

        // Loop reached iteration limit without natural termination:
        // Ask the model for a final synthesis rather than leaving the user with an error.
        let finalPrompt = "All terminal inspection commands have been completed. Based on all command outputs above, please provide your final conclusion and answer the user's original request: '\(input)'. Do not call any tools."
        messages.append(.user(finalPrompt))
        do {
            let finalTurn = try await toolContext.llmProvider.chat(
                messages: messages,
                maxTokens: 2048,
                disableReasoning: false
            )
            let answer = finalTurn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty {
                appendAgentMessage(
                    .assistant,
                    content: answer,
                    conversation: toolContext.conversation,
                    context: toolContext.context
                )
                return
            }
        } catch {
            // Fall back to polite summary notice
        }

        appendAgentMessage(
            .system,
            content: String(format: "已执行完成 %d 轮终端命令，请参考上方执行结果。", maxIterations),
            conversation: toolContext.conversation, context: toolContext.context
        )
    }

    /// One model round-trip: call the API, surface the model's text, execute
    /// any requested tools, and return the extended message history.
    private func runToolIteration(
        iteration: Int,
        input: String,
        toolContext: AgentToolContext,
        messages: [LLMMessage],
        terminationGuard: TerminationGuard
    ) async -> (messages: [LLMMessage], finished: Bool) {
        let turn: AgentChatTurn
        do {
            turn = try await toolContext.llmProvider.toolCall(
                messages: messages,
                tools: AgentTools.definitions,
                maxTokens: nil
            )
        } catch {
            if iteration == 0 {
                appendAgentMessage(
                    .system,
                    content: "Tool calling unavailable, falling back to plan mode.",
                    conversation: toolContext.conversation, context: toolContext.context
                )
                await runAgentLegacy(
                    input: input, sshService: toolContext.sshService,
                    conversation: toolContext.conversation, context: toolContext.context
                )
            } else {
                appendAgentMessage(
                    .system,
                    content: "AI error: \(error.localizedDescription)",
                    conversation: toolContext.conversation, context: toolContext.context
                )
            }
            return (messages, true)
        }

        if let content = turn.content,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            appendAgentMessage(
                .assistant, content: content,
                conversation: toolContext.conversation, context: toolContext.context
            )
        }

        guard !turn.toolCalls.isEmpty else {
            if (turn.content ?? "").isEmpty {
                appendAgentMessage(
                    .system, content: L.t(.aiNoResponse),
                    conversation: toolContext.conversation, context: toolContext.context
                )
            }
            return (messages, true)
        }

        var nextMessages = messages
        nextMessages.append(LLMMessage(
            role: .assistant,
            content: turn.text,
            toolCalls: turn.toolCalls
        ))
        let toolResults = await executeToolCalls(
            turn.toolCalls, toolContext: toolContext
        )
        nextMessages.append(contentsOf: toolResults)

        // Evaluate progress via TerminationGuard to detect anti-patterns / loops
        for (call, result) in zip(turn.toolCalls, toolResults) {
            let eval = terminationGuard.recordAndEvaluate(
                toolName: call.name,
                arguments: call.argumentsJSON,
                output: result.content
            )
            switch eval {
            case .proceed:
                break
            case .warnDuplicate(let toolName):
                nextMessages.append(.system("提示：你刚刚重复调用了 '\(toolName)' 并得到了相同输出。如果已有足够信息，请停止调用工具并直接给出最终结论。"))
            case .terminateLoop(let reason):
                appendAgentMessage(.system, content: reason, conversation: toolContext.conversation, context: toolContext.context)
                return (nextMessages, true)
            }
        }
        return (nextMessages, false)
    }

    /// Run each requested tool call and return the `tool` messages to feed
    /// back into the conversation.
    private func executeToolCalls(
        _ calls: [AgentToolCall],
        toolContext: AgentToolContext
    ) async -> [LLMMessage] {
        var results: [LLMMessage] = []
        for call in calls {
            let outcome: String
            if call.name == AgentTools.runCommandName,
               let command = call.arguments["command"] as? String, !command.isEmpty
            {
                outcome = await executeAgentCommand(
                    command, toolContext: toolContext
                )
            } else {
                outcome = "Error: unknown tool or missing command argument."
            }
            results.append(LLMMessage(
                role: .tool,
                content: outcome,
                toolCallID: call.id
            ))
        }
        return results
    }

    /// Execute one tool command with the same safety pipeline as plan mode:
    /// blocked → refuse, moderate/dangerous → confirm, then run with timeout.
    private func executeAgentCommand(
        _ command: String,
        toolContext: AgentToolContext
    ) async -> String {
        appendAgentMessage(
            .commandOutput, content: "", command: command,
            status: .running,
            conversation: nil, context: nil
        )

        let risk = CommandSafety.classify(command)
        if risk == .blocked {
            if let last = agentMessages.last, last.role == .commandOutput, last.command == command, last.status == .running {
                agentMessages.removeLast()
            }
            let message = "Blocked: \(command) violates the safety policy."
            appendAgentMessage(
                .commandOutput, content: message, command: command,
                status: .blocked,
                conversation: toolContext.conversation, context: toolContext.context
            )
            mirror(command: command, status: .blocked, output: message, toolContext: toolContext)
            return message
        }

        let accessMode = AgentEngine.accessMode
        if accessMode == .readOnly && risk != .safe {
            if let last = agentMessages.last, last.role == .commandOutput, last.command == command, last.status == .running {
                agentMessages.removeLast()
            }
            let message = "已处于只读模式（Read-Only），已阻止修改命令：\(command)"
            appendAgentMessage(
                .commandOutput, content: message, command: command,
                status: .blocked,
                conversation: toolContext.conversation, context: toolContext.context
            )
            mirror(command: command, status: .blocked, output: message, toolContext: toolContext)
            return message
        }

        if accessMode == .fullAccess {
            // Full Access: automatically execute safe and moderate commands!
            // Only confirm dangerous commands (e.g. rm -rf, mkfs, dd)
            if risk == .dangerous {
                let confirmed = await requestConfirmation(command: command, riskLevel: .dangerous)
                guard confirmed else {
                    if let last = agentMessages.last, last.role == .commandOutput, last.command == command, last.status == .running {
                        agentMessages.removeLast()
                    }
                    let message = "Skipped by user."
                    appendAgentMessage(
                        .commandOutput, content: message, command: command,
                        status: .skipped,
                        conversation: toolContext.conversation, context: toolContext.context
                    )
                    mirror(command: command, status: .skipped, output: message, toolContext: toolContext)
                    return message
                }
            }
        } else {
            // Supervised mode: confirm moderate and dangerous commands
            if risk != .safe {
                let riskLevel: PendingCommand.RiskLevel = risk == .dangerous ? .dangerous : .moderate
                let confirmed = await requestConfirmation(command: command, riskLevel: riskLevel)
                guard confirmed else {
                    if let last = agentMessages.last, last.role == .commandOutput, last.command == command, last.status == .running {
                        agentMessages.removeLast()
                    }
                    let message = "Skipped by user."
                    appendAgentMessage(
                        .commandOutput, content: message, command: command,
                        status: .skipped,
                        conversation: toolContext.conversation, context: toolContext.context
                    )
                    mirror(command: command, status: .skipped, output: message, toolContext: toolContext)
                    return message
                }
            }
        }

        do {
            let start = Date()
            let hybridExec = toolContext.hybridExec
            let sshService = toolContext.sshService
            let output = try await withTimeout(seconds: 30) {
                if let exec = hybridExec {
                    return try await exec(command)
                }
                return try await sshService.executeCommand(command)
            }
            let duration = Date().timeIntervalSince(start)
            let guarded = OutputGuard.guardOutput(output)
            let message = guarded.content.isEmpty ? "(no output)" : guarded.content
            if let last = agentMessages.last, last.role == .commandOutput, last.command == command, last.status == .running {
                agentMessages.removeLast()
            }
            appendAgentMessage(
                .commandOutput, content: message, command: command,
                status: .success, duration: duration,
                conversation: toolContext.conversation, context: toolContext.context
            )
            mirror(
                command: command, status: .success, duration: duration,
                output: message, toolContext: toolContext
            )
            OperationLog.shared.record(command: command, output: message, success: true)
            return message
        } catch {
            let message = "Error: \(error.localizedDescription)"
            if let last = agentMessages.last, last.role == .commandOutput, last.command == command, last.status == .running {
                agentMessages.removeLast()
            }
            appendAgentMessage(
                .commandOutput, content: message, command: command,
                status: .failed,
                conversation: toolContext.conversation, context: toolContext.context
            )
            mirror(command: command, status: .failed, output: message, toolContext: toolContext)
            OperationLog.shared.record(command: command, output: message, success: false)
            return message
        }
    }

    private func mirror(
        command: String,
        status: AgentMessage.CommandStatus,
        duration: TimeInterval? = nil,
        output: String,
        toolContext: AgentToolContext
    ) {
        AITerminalMirror.post(
            command: command, status: status, duration: duration,
            output: output, hostName: toolContext.hostName
        )
    }
}
