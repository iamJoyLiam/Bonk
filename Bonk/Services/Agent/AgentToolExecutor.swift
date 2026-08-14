import Foundation
import SwiftData

/// Bundle of long-lived state for one tool-loop run. Keeps helper signatures
/// small instead of threading five parameters through every call.
private struct AgentToolContext {
    let provider: AIProviderConfig
    let apiKey: String
    let sshService: SSHNetworkService
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
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async {
        guard let (provider, apiKey) = resolveProvider() else { return }
        let toolContext = AgentToolContext(
            provider: provider, apiKey: apiKey,
            sshService: sshService, conversation: conversation, context: context
        )

        let systemPrompt = CustomInstructions.buildSystemPrompt(base: AgentPrompts.toolSystemPrompt)
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": input],
        ]

        for iteration in 0 ..< Self.maxAgentIterations {
            guard !Task.isCancelled else { break }
            let result = await runToolIteration(
                iteration: iteration, input: input,
                toolContext: toolContext, messages: messages
            )
            messages = result.messages
            if result.finished { return }
        }

        appendAgentMessage(
            .system,
            content: String(format: "Reached iteration limit (%d tool rounds).", Self.maxAgentIterations),
            conversation: toolContext.conversation, context: toolContext.context
        )
    }

    /// One model round-trip: call the API, surface the model's text, execute
    /// any requested tools, and return the extended message history.
    private func runToolIteration(
        iteration: Int,
        input: String,
        toolContext: AgentToolContext,
        messages: [[String: Any]]
    ) async -> (messages: [[String: Any]], finished: Bool) {
        let turn: AgentChatTurn
        do {
            turn = try await AIProviderNetworking.agentChat(
                provider: toolContext.provider, apiKey: toolContext.apiKey,
                messages: messages, tools: AgentTools.definitions
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

        if let content = turn.content, !content.isEmpty {
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
        nextMessages.append([
            "role": "assistant",
            "content": turn.content ?? "",
            "tool_calls": turn.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.argumentsJSON],
                ]
            },
        ])
        nextMessages.append(contentsOf: await executeToolCalls(
            turn.toolCalls, toolContext: toolContext
        ))
        return (nextMessages, false)
    }

    /// Run each requested tool call and return the `tool` messages to feed
    /// back into the conversation.
    private func executeToolCalls(
        _ calls: [AgentToolCall],
        toolContext: AgentToolContext
    ) async -> [[String: Any]] {
        var results: [[String: Any]] = []
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
            results.append(["role": "tool", "tool_call_id": call.id, "content": outcome])
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
            .system, content: "Running: \(command)",
            conversation: toolContext.conversation, context: toolContext.context
        )

        let risk = CommandSafety.classify(command)
        if risk == .blocked {
            let message = "Blocked: \(command) violates the safety policy."
            appendAgentMessage(
                .commandOutput, content: message, command: command,
                status: .blocked,
                conversation: toolContext.conversation, context: toolContext.context
            )
            return message
        }

        if risk != .safe {
            let riskLevel: PendingCommand.RiskLevel = risk == .dangerous ? .dangerous : .moderate
            let confirmed = await requestConfirmation(command: command, riskLevel: riskLevel)
            guard confirmed else {
                let message = "Skipped by user."
                appendAgentMessage(
                    .commandOutput, content: message, command: command,
                    status: .skipped,
                    conversation: toolContext.conversation, context: toolContext.context
                )
                return message
            }
        }

        do {
            let sshService = toolContext.sshService
            let start = Date()
            let output = try await withTimeout(seconds: 30) {
                try await sshService.executeCommand(command)
            }
            let duration = Date().timeIntervalSince(start)
            let truncated = String(output.prefix(4000))
            let message = truncated.isEmpty ? "(no output)" : truncated
            appendAgentMessage(
                .commandOutput, content: message, command: command,
                status: .success, duration: duration,
                conversation: toolContext.conversation, context: toolContext.context
            )
            OperationLog.shared.record(command: command, output: truncated, success: true)
            return message
        } catch {
            let message = "Error: \(error.localizedDescription)"
            appendAgentMessage(
                .commandOutput, content: message, command: command,
                status: .failed,
                conversation: toolContext.conversation, context: toolContext.context
            )
            OperationLog.shared.record(command: command, output: message, success: false)
            return message
        }
    }
}
