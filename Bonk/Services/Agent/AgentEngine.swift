import Foundation
import os.log
import SwiftData

/// Central AI agent engine. Manages all three modes (Ask/Edit/Agent)
/// with unified state, request building, and safety controls.
@Observable @MainActor
final class AgentEngine {
    static let shared = AgentEngine()

    private static let logger = Logger(subsystem: "com.bonk", category: "AgentEngine")
    /// Cap on tool-loop rounds before the agent is forced to answer.
    nonisolated static let maxAgentIterations = 8

    // MARK: - Unified State

    var isProcessing = false
    var streamingResponse = ""
    var currentExplanation: String?
    var lastError: String?
    var activeProvider: AIProviderConfig?

    // Agent-specific state
    var agentMessages: [AgentMessage] = []
    var pendingConfirmation: PendingCommand?

    private var currentTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let providerStore: AIProviderStore
    private let conversationStore: AIConversationStore
    let sanitizer = AIOutputSanitizer.self

    // Plan approval state
    var currentPlan: AgentPlan?
    var planApprovalContinuation: CheckedContinuation<Bool, Never>?

    init(providerStore: AIProviderStore = .shared, conversationStore: AIConversationStore = .shared) {
        self.providerStore = providerStore
        self.conversationStore = conversationStore
    }

    // MARK: - Provider Resolution

    func resolveProvider() -> (AIProviderConfig, String)? {
        let provider = activeProvider ?? providerStore.activeProvider
        guard let provider else {
            lastError = L.t(.noActiveProvider)
            return nil
        }
        let key = provider.apiKey
        guard !key.isEmpty else {
            lastError = String(format: L.t(.apiKeyNotSet), provider.name)
            return nil
        }
        activeProvider = provider
        return (provider, key)
    }

    // MARK: - Unified Entry Point

    /// Execute an AI request in the specified mode.
    /// Returns the response text. For streaming modes, updates `streamingResponse` in real-time.
    func execute(
        input: String,
        mode: AIMode,
        context: TerminalContext = TerminalContext(),
        systemPromptOverride: String? = nil
    ) async -> String? {
        isProcessing = true
        streamingResponse = ""
        defer { isProcessing = false }

        guard let (provider, apiKey) = resolveProvider() else {
            return nil
        }

        var basePrompt = systemPromptOverride ?? mode.systemPrompt
        if let ctx = buildContextString(context) {
            basePrompt += "\n\n## Terminal Context\n\(ctx)"
        }
        let systemPrompt = CustomInstructions.buildSystemPrompt(base: basePrompt)
        let label = mode.rawValue

        // swiftlint:disable:next line_length
        Self.logger.info("\(label, privacy: .public): provider=\(provider.name, privacy: .public) model=\(provider.model, privacy: .public)")

        let maxRetries = 2
        for attempt in 0 ... maxRetries {
            do {
                let response: String = if mode == .agent {
                    try await executeNonStreaming(
                        provider: provider, apiKey: apiKey,
                        systemPrompt: systemPrompt, userPrompt: input
                    )
                } else {
                    try await executeStreaming(
                        provider: provider, apiKey: apiKey,
                        systemPrompt: systemPrompt, userPrompt: input
                    )
                }

                let sanitized = sanitizer.sanitize(response)

                if sanitized.isEmpty {
                    // swiftlint:disable:next line_length
                    Self.logger.warning("\(label, privacy: .public): empty response from \(provider.name, privacy: .public)")
                }

                currentExplanation = sanitized
                return sanitized
            } catch {
                if Task.isCancelled {
                    return nil
                }

                // Don't retry non-retryable errors (auth failures, client errors)
                if let aiError = error as? AIError, !aiError.isRetryable {
                    lastError = error.localizedDescription
                    let errorMsg = error.localizedDescription
                    Self.logger.error(
                        "\(label, privacy: .public): non-retryable error: \(errorMsg, privacy: .public)"
                    )
                    return nil
                }

                if attempt < maxRetries {
                    Self.logger.warning(
                        "\(label, privacy: .public): attempt \(attempt + 1) failed, retrying"
                    )
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                } else {
                    lastError = error.localizedDescription
                    // swiftlint:disable:next line_length
                    Self.logger.error("\(label, privacy: .public): all attempts failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return nil
    }

    // MARK: - Streaming Execution (Ask/Edit)

    private func executeStreaming(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        var lastUIUpdate = Date.distantPast
        return try await AIProviderNetworking.streamRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt
        ) { [weak self] delta in
            guard let self else { return }
            let now = Date()
            if now.timeIntervalSince(lastUIUpdate) > 0.1 {
                streamingResponse += delta
                lastUIUpdate = now
            }
        }
    }

    // MARK: - Non-Streaming Execution (Agent)

    func executeNonStreaming(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        try await AIProviderNetworking.nonStreamRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt
        )
    }

    // MARK: - Agent Mode (Plan → Approve → Execute)

    // Implementation moved to AgentPlanExecutor.swift

    /// Append an agent message to in-memory list and optionally persist to SwiftData.
    func appendAgentMessage(
        _ role: AgentMessage.Role,
        content: String,
        thinking: String? = nil,
        command: String? = nil,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) {
        agentMessages.append(AgentMessage(role: role, content: content, command: command, thinking: thinking))

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

    /// Build context string from terminal state.
    private func buildContextString(_ context: TerminalContext) -> String? {
        var parts: [String] = []
        if let cwd = context.currentDirectory { parts.append("Working directory: `\(cwd)`") }
        if let shell = context.shell { parts.append("Shell: \(shell)") }
        if !context.recentCommands.isEmpty {
            let cmds = context.recentCommands.suffix(5).joined(separator: ", ")
            parts.append("Recent commands: \(cmds)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func buildAgentMessages() -> [[String: String]] {
        var messages: [[String: String]] = []
        for msg in agentMessages.suffix(20) {
            messages.append(contentsOf: msg.toAIMessages())
        }
        return messages
    }

    func requestConfirmation(command: String, riskLevel: PendingCommand.RiskLevel) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingConfirmation = PendingCommand(
                command: command,
                reason: riskLevel == .dangerous ? L.t(.dangerousCommand) : L.t(.moderate),
                riskLevel: riskLevel,
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
        if let pending = pendingConfirmation {
            pending.continuation(false)
            pendingConfirmation = nil
        }
        planApprovalContinuation?.resume(returning: false)
        planApprovalContinuation = nil
        currentPlan = nil
        streamingResponse = ""
        currentExplanation = nil
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
        case .edit:
            """
            You are a terminal command expert. The user describes a task and you produce
            the exact commands to run on their remote server.

            Output rules (strict):
            - Put the commands in ONE ```bash block, runnable as-is.
            - Lead with the block. A 1-2 sentence note only when a command is
              destructive or surprising.
            - Sparse same-line `#` comments only.
            - No numbered lists, no extra formatting inside the block.
            - Prefer read-only commands first; warn before irreversible operations.
            - Match the user's language.
            """
        case .agent:
            AgentPrompts.systemPrompt
        }
    }
}
