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
        projectInstructions: String? = nil,
        skillListing: String? = nil,
        hostScope: String? = nil
    ) async {
        let llmProvider = provider

        // The model's memory of this conversation, so the loop begins from
        // the conversation's prior turns instead of from a bare
        // `[system, user]`.
        //
        // When the conversation and the store are both there, the memory
        // is the **stored** one: a run that starts from a conversation the
        // app has forgotten is not a continuation, it is a first turn that
        // happens to look like a second one. Without a store to write to,
        // the in-memory history is the best there is.
        let messageHistory: (any AgentMessageHistory)?
        if let conversation, let context {
            messageHistory = PersistentAgentMessageHistory(
                context: context,
                conversation: conversation
            )
        } else {
            agentMessageHistory.bind(to: conversation?.id)
            messageHistory = agentMessageHistory
        }

        let modelGateway = LLMProviderModelGateway(provider: llmProvider)
        let contextProvider = DefaultAgentContextProvider(
            hostInfo: hostName
        )
        let permissionPolicy = permissionPolicyFactory(hostScope)
        let runtime = AgentRuntime(
            contextProvider: contextProvider,
            modelGateway: modelGateway,
            permissionPolicy: permissionPolicy,
            executionManager: executionManager,
            maxIterations: AgentEngine.maxAgentIterations,
            decisionMemory: decisionMemory,
            foldEngine: DecisionEngineFactory.makeEffective(),
            progressEngine: DecisionEngineFactory.makeEffective(),
            messageHistory: messageHistory,
            projectInstructions: projectInstructions,
            skillListing: skillListing,
            hostScope: hostScope
        )

        self.activeRuntime = runtime
        self.activeRunAccessMode = AgentEngine.accessMode
        self.activeRunHostScope = hostScope
        defer {
            if self.activeRuntime === runtime {
                self.activeRuntime = nil
            }
            self.activeRunAccessMode = nil
            self.activeRunHostScope = nil
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

        // Which message belongs to which call.
        //
        // Calls can run at the same time, so one call's output does not
        // necessarily arrive right after that call started, and it
        // certainly does not arrive after the *last* call started. The
        // call's own id is the only thing that says which message the
        // output belongs to.
        var messageIDByCallID: [String: UUID] = [:]

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

            case let .todoListUpdated(items):
                // The model wrote its task list. The app shows it; it does
                // not interpret it.
                currentTodos = items

            case let .assistantTextDelta(delta):
                // A piece of the answer as it arrives. Appended, not
                // replaced: the pieces are the answer, and the user should
                // watch it being written.
                if let lastIndex = agentMessages.indices.last, agentMessages[lastIndex].role == .assistant {
                    agentMessages[lastIndex].content += delta
                } else {
                    appendAgentMessage(.assistant, content: delta, conversation: conversation, context: context)
                }

            case let .thinking(thought):
                if let lastIndex = agentMessages.indices.last, agentMessages[lastIndex].role == .assistant {
                    agentMessages[lastIndex].thinking = thought
                }

            case let .toolCallStarted(id, _, inputArgs):
                let argsDict = (try? JSONSerialization.jsonObject(with: Data(inputArgs.utf8)) as? [String: Any]) ?? [:]
                let cmd = (argsDict["command"] as? String) ?? inputArgs
                let msg = AgentMessage(
                    role: .commandOutput,
                    content: "",
                    command: cmd,
                    status: .running
                )
                agentMessages.append(msg)
                messageIDByCallID[id] = msg.id

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

            case let .toolOutput(id, output):
                if let index = Self.indexOfMessage(id, in: messageIDByCallID, messages: agentMessages) {
                    agentMessages[index].content = output
                }

            case let .toolCompleted(id, exitCode, duration):
                if let index = Self.indexOfMessage(id, in: messageIDByCallID, messages: agentMessages) {
                    agentMessages[index].status = (exitCode == 0 ? .success : .failed)
                    agentMessages[index].duration = duration
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

    /// The message a call's output belongs to.
    ///
    /// The call's id is the link: with calls running at the same time,
    /// "the last message" is whichever call happened to start last, which
    /// is not the call that produced this output.
    nonisolated static func indexOfMessage(
        _ callID: String,
        in messageIDByCallID: [String: UUID],
        messages: [AgentMessage]
    ) -> Int? {
        guard let messageID = messageIDByCallID[callID] else { return nil }
        return messages.firstIndex { $0.id == messageID }
    }
}
