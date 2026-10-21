import Foundation
import SwiftData

/// Real agentic loop: the model calls `run_command`, the engine executes on
/// the SSH session (safety-classified, user-confirmed when risky), output feeds
/// back into the conversation, and the loop repeats until the model answers.
extension AgentEngine {
    // MARK: - Tool-Calling Agent Loop (OpenAI-compatible providers)

    /// v3.3 Hybrid overload — when a TerminalSession with vnextSession is available,
    /// exec reuses the multiplexed channel (Native 1000× channel vs 1000× Process).
    ///
    /// The provider is resolved by the caller and passed in. Resolving it again
    /// here would let the decision (tool loop or plan flow) and the run be
    /// made against different providers.
    func runAgentToolLoop(
        input: String,
        sshService: SSHNetworkService,
        hybridSession: TerminalSession?,
        hostName: String?,
        conversation: AIConversationRecord?,
        context: ModelContext?,
        provider: any LLMProvider,
        projectInstructions: String? = nil
    ) async {
        let llmProvider = provider

        // Bind the model's memory to this conversation before the run starts,
        // so the loop begins from the conversation's prior turns instead of
        // from a bare `[system, user]`.
        agentMessageHistory.bind(to: conversation?.id)

        let modelGateway = LLMProviderModelGateway(provider: llmProvider)
        let contextProvider = DefaultAgentContextProvider(
            hostInfo: hostName
        )
        let permissionPolicy = permissionPolicyFactory()
        let runtime = AgentRuntime(
            contextProvider: contextProvider,
            modelGateway: modelGateway,
            permissionPolicy: permissionPolicy,
            executionManager: executionManager,
            maxIterations: AgentEngine.maxAgentIterations,
            decisionMemory: decisionMemory,
            foldEngine: DecisionEngineFactory.makeEffective(),
            progressEngine: DecisionEngineFactory.makeEffective(),
            messageHistory: agentMessageHistory,
            projectInstructions: projectInstructions
        )

        self.activeRuntime = runtime
        self.activeRunAccessMode = AgentEngine.accessMode
        defer {
            if self.activeRuntime === runtime {
                self.activeRuntime = nil
            }
            self.activeRunAccessMode = nil
        }

        let executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32) = { command, registerHandle in
            if let session = hybridSession {
                let out = try await session.executeHybrid(command, registerHandle: registerHandle)
                return (out, 0)
            } else {
                let out = try await sshService.executeCommand(command, registerHandle: registerHandle)
                return (out, 0)
            }
        }

        let eventStream = runtime.run(input: input, executor: executor)

        for await event in eventStream {
            switch event {
            case .userMessage:
                break

            case let .assistantText(text):
                if let lastIndex = agentMessages.indices.last, agentMessages[lastIndex].role == .assistant {
                    agentMessages[lastIndex].content = text
                } else {
                    appendAgentMessage(.assistant, content: text, conversation: conversation, context: context)
                }

            case let .thinking(thought):
                if let lastIndex = agentMessages.indices.last, agentMessages[lastIndex].role == .assistant {
                    agentMessages[lastIndex].thinking = thought
                }

            case let .toolCallStarted(_, _, inputArgs):
                let argsDict = (try? JSONSerialization.jsonObject(with: Data(inputArgs.utf8)) as? [String: Any]) ?? [:]
                let cmd = (argsDict["command"] as? String) ?? inputArgs
                let msg = AgentMessage(
                    role: .commandOutput,
                    content: "",
                    command: cmd,
                    status: .running
                )
                agentMessages.append(msg)

            case let .permissionRequested(id, description, level, reason):
                let riskLevel: PendingCommand.RiskLevel = (level == .confirmRequired ? .moderate : .dangerous)
                let confirmed = await requestConfirmation(command: description, riskLevel: riskLevel, reasonDetail: reason)
                runtime.resolvePermission(id: id, approved: confirmed)

            case .permissionResolved:
                pendingConfirmation = nil

            case let .permissionFolded(_, _, level, engine):
                // Fold fact, not an approval: the command ran under an
                // existing .confirmRequired verdict. History word is
                // implied (only previously-approved commands fold).
                appendAgentMessage(
                    .system,
                    content: String(
                        format: L.t(.foldNotice), level,
                        L.t(.confirmHistApproved), engine
                    ),
                    conversation: conversation, context: context
                )

            case let .toolOutput(_, output):
                if let lastIndex = agentMessages.indices.last, agentMessages[lastIndex].role == .commandOutput {
                    agentMessages[lastIndex].content = output
                }

            case let .toolCompleted(_, exitCode, duration):
                if let lastIndex = agentMessages.indices.last, agentMessages[lastIndex].role == .commandOutput {
                    agentMessages[lastIndex].status = (exitCode == 0 ? .success : .failed)
                    agentMessages[lastIndex].duration = duration
                }

            case let .executionInterrupted(reason):
                appendAgentMessage(.system, content: reason, conversation: conversation, context: context)

            case let .error(code, message):
                // errorCode is in-memory only (SwiftData records carry no
                // code); reloaded history renders generic. Acceptable:
                // typing serves the live run, audit lives in the trace.
                appendAgentMessage(.system, content: message, errorCode: code, conversation: conversation, context: context)

            case .contextCompacted:
                // UI-only note: history was compacted, task state preserved.
                // AgentMessage transcripts never feed the model, so this
                // cannot pollute model context by construction.
                appendAgentMessage(.system, content: L.t(.compactionNote), conversation: conversation, context: context)

            case .completed:
                break
            }
        }
    }
}
