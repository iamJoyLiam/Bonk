import Foundation
import os.log
import SwiftData

/// Central AI agent engine. Manages all three modes (Ask/Edit/Agent)
/// with unified state, request building, and safety controls.
@Observable @MainActor
final class AgentEngine {
    static let shared = AgentEngine()

    private static let logger = Logger(subsystem: "com.bonk", category: "AgentEngine")

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

    private let providerStore = AIProviderStore.shared
    private let conversationStore = AIConversationStore.shared
    internal let sanitizer = AIOutputSanitizer.self
    private var lastUIUpdate = Date.distantPast

    // Plan approval state
    var currentPlan: AgentPlan?
    var planApprovalContinuation: CheckedContinuation<Bool, Never>?

    private init() {}

    // MARK: - Provider Resolution

    func resolveProvider() -> (AIProviderConfig, String)? {
        let provider = activeProvider ?? providerStore.activeProvider
        guard let provider else {
            lastError = "No active AI provider configured"
            return nil
        }
        let key = provider.apiKey
        guard !key.isEmpty else {
            lastError = "API key not set for \(provider.name)"
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
        context: TerminalContext = TerminalContext()
    ) async -> String? {
        isProcessing = true
        streamingResponse = ""

        guard let (provider, apiKey) = resolveProvider() else {
            isProcessing = false
            return nil
        }

        var basePrompt = mode.systemPrompt
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
                    isProcessing = false
                    return nil
                }

                // Don't retry non-retryable errors (auth failures, client errors)
                if let aiError = error as? AIError, !aiError.isRetryable {
                    lastError = error.localizedDescription
                    Self.logger.error("\(label, privacy: .public): non-retryable error: \(error.localizedDescription, privacy: .public)")
                    isProcessing = false
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
        isProcessing = false
        return nil
    }

    // MARK: - Streaming Execution (Ask/Edit)

    private func executeStreaming(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let request = try AIProviderNetworking.buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            stream: true
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let body = String(data: errorData, encoding: .utf8) ?? "Unknown"
            throw AIError.apiError(statusCode: http.statusCode, message: body)
        }

        return try await parseStream(bytes: bytes, providerType: provider.type)
    }

    // MARK: - Non-Streaming Execution (Agent)

    func executeNonStreaming(
        provider: AIProviderConfig,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let request = try AIProviderNetworking.buildRequest(
            provider: provider, apiKey: apiKey,
            systemPrompt: systemPrompt, userPrompt: userPrompt,
            stream: false
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw AIError.apiError(statusCode: code, message: body)
        }

        return try AIProviderNetworking.extractResponse(from: data, type: provider.type)
    }

    // MARK: - Stream Parsing

    private func parseStream(
        bytes: URLSession.AsyncBytes,
        providerType _: AIProviderType
    ) async throws -> String {
        var result = ""
        var buffer = ""

        var lastUIUpdate = Date.distantPast

        for try await byte in bytes {
            guard !Task.isCancelled else { break }
            guard let char = String(bytes: [byte], encoding: .utf8) else { continue }
            buffer += char

            while let range = buffer.range(of: "\n") {
                let line = String(buffer[buffer.startIndex ..< range.lowerBound])
                buffer = String(buffer[range.upperBound...])

                guard line.hasPrefix("data: ") else { continue }
                let json = String(line.dropFirst(6))
                guard json != "[DONE]" else { continue }
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                if let text = AIProviderNetworking.extractDelta(from: obj) {
                    result += text
                    // Update UI every 100ms to prevent excessive redraws
                    let now = Date()
                    if now.timeIntervalSince(lastUIUpdate) > 0.1 {
                        streamingResponse = result
                        lastUIUpdate = now
                    }
                }
            }
        }

        // Final update — ensure UI has the complete text
        streamingResponse = result
        return result
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
                reason: riskLevel == .dangerous ? "Dangerous command" : "Moderate command",
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
        pendingConfirmation = nil
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
            let result = try await group.next()!
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
            You are a strictly technical SSH terminal assistant for a native macOS client.

            <contract>
            - RESPONSE FORMAT: Output exactly ONE bold title, then ONE fenced code block, then ONE explanation list.
            - NO EXCEPTION: Do NOT open multiple code blocks. Do NOT split commands across blocks.
            - COMMENT RULE: Inline comments in the code block must be on the SAME line using #.
            - EXPLANATIONS: Must be OUTSIDE and BELOW the code block as bullet list.
            </contract>

            <output_template>
            **[Brief Title]**
            ```bash
            [All executable commands combined here]
            ```
            - `[term]`: [Explanation]
            </output_template>

            Example:
            **Docker Image Import Guide:**
            ```bash
            docker load -i app.tar # Load image from tarball
            docker run -d --name my-app app:latest # Run container
            ```
            - `docker load`: Restores the image repository from a file.
            - `-i`: Specifies the input archive file path.
            - `docker network`: Manages networks.
            - `docker run`: Runs the container.
            """
        case .edit:
            """
            You are a strictly technical SSH terminal assistant for a native macOS client.

            ## OUTPUT RULES (STRICTLY ENFORCED)
            1. Brief explanation BEFORE the code block (1-2 sentences, plain text)
            2. Commands in a SINGLE ```bash code block
            3. Inside code blocks: ONLY executable shell lines
            4. Comments MUST be appended to the same line using `#`
            5. NEVER use numbered lists inside code blocks
            6. All step descriptions go OUTSIDE the code block

            CORRECT:
            Create a network and run a container:

            ```bash
            docker network create mynet # Create network
            docker run -d --name nginx --network mynet nginx # Start container
            ```

            WRONG (NEVER do this):
            ```bash
            # Docker
            1. docker network create mynet
            docker run nginx #
            ```

            ## Safety
            - Prefer read-only commands
            - Warn about irreversible operations
            - Suggest --dry-run when available
            """
        case .agent:
            AgentPrompts.systemPrompt
        }
    }
}
