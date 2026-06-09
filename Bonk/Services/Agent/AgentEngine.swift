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
    private let sanitizer = AIOutputSanitizer.self

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
        context _: TerminalContext = TerminalContext()
    ) async -> String? {
        guard let (provider, apiKey) = resolveProvider() else { return nil }

        let systemPrompt = mode.systemPrompt
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
                if sanitized != response {
                    Self.logger.warning("\(label, privacy: .public): output sanitized")
                }

                if sanitized.isEmpty {
                    // swiftlint:disable:next line_length
                    Self.logger.warning("\(label, privacy: .public): empty response from \(provider.name, privacy: .public)")
                }

                currentExplanation = sanitized
                return sanitized
            } catch {
                if Task.isCancelled { return nil }
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

    private func executeNonStreaming(
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

        for try await byte in bytes {
            guard !Task.isCancelled else { break }
            guard let char = String(bytes: [byte], encoding: .utf8) else { continue }
            buffer += char

            while let range = buffer.range(of: "\n") {
                let line = String(buffer[buffer.startIndex ..< range.lowerBound])
                buffer = String(buffer[range.upperBound...])

                guard line.hasPrefix("data: ") else { continue }
                let json = String(line.dropFirst(6))
                guard json != "[DONE]",
                      let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                if let text = AIProviderNetworking.extractDelta(from: obj) {
                    result += text
                    streamingResponse = result
                }
            }
        }
        return result
    }

    // MARK: - Agent Mode

    /// Run the agent loop: AI → parse command → safety check → confirm → execute → repeat.
    func runAgent(
        input: String,
        sshService: SSHNetworkService,
        conversation: AIConversationRecord? = nil,
        context: ModelContext? = nil
    ) async {
        appendAgentMessage(.user, content: input, conversation: conversation, context: context)

        for _ in 0 ..< 10 {
            guard !Task.isCancelled else {
                appendAgentMessage(.system, content: "Cancelled.", conversation: conversation, context: context)
                return
            }

            let shouldContinue = await runAgentIteration(
                sshService: sshService, conversation: conversation, context: context
            )
            guard shouldContinue else { return }
        }

        appendAgentMessage(
            .system, content: "Reached maximum iterations (10). Stopping.",
            conversation: conversation, context: context
        )
    }

    /// Single iteration of the agent loop. Returns false if the loop should stop.
    private func runAgentIteration(
        sshService: SSHNetworkService,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async -> Bool {
        let aiMessages = buildAgentMessages()
        guard let (provider, apiKey) = resolveProvider() else {
            appendAgentMessage(.system, content: lastError ?? "No provider",
                               conversation: conversation, context: context)
            return false
        }

        // Call AI
        let response: String
        do {
            let prompt = aiMessages.map { "\($0["role"] ?? "user"): \($0["content"] ?? "")" }
                .joined(separator: "\n\n")
            response = try await executeNonStreaming(
                provider: provider, apiKey: apiKey,
                systemPrompt: AgentPrompts.systemPrompt, userPrompt: prompt
            )
        } catch {
            appendAgentMessage(.system, content: "AI error: \(error.localizedDescription)",
                               conversation: conversation, context: context)
            return false
        }

        let sanitized = sanitizer.sanitize(response)
        let parsed = ResponseParser.parse(sanitized)

        appendAgentMessage(.assistant, content: parsed.response,
                           thinking: parsed.thinking, command: parsed.command,
                           conversation: conversation, context: context)

        guard let command = parsed.command, !command.isEmpty else { return false }

        // Safety check
        let safety = CommandSafety.classify(command)
        if safety == .blocked {
            appendAgentMessage(.system, content: "Blocked: \(command)",
                               conversation: conversation, context: context)
            return false
        }

        if safety == .dangerous || safety == .moderate {
            let riskLevel: PendingCommand.RiskLevel = safety == .dangerous ? .dangerous : .moderate
            let confirmed = await requestConfirmation(command: command, riskLevel: riskLevel)
            guard confirmed else {
                appendAgentMessage(.system, content: "Declined: \(command)",
                                   conversation: conversation, context: context)
                return false
            }
        }

        // Execute via SSH
        do {
            let output = try await withTimeout(seconds: 30) {
                try await sshService.executeCommand(command)
            }
            let truncated = String(output.prefix(4000))
            appendAgentMessage(.commandOutput, content: truncated,
                               conversation: conversation, context: context)
            OperationLog.shared.record(command: command, output: truncated, success: true)
        } catch {
            let errorMsg = "Execution failed: \(error.localizedDescription)"
            appendAgentMessage(.system, content: errorMsg,
                               conversation: conversation, context: context)
            OperationLog.shared.record(command: command, output: errorMsg, success: false)
            return false
        }

        return true
    }

    /// Append an agent message to in-memory list and optionally persist to SwiftData.
    private func appendAgentMessage(
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

    private func buildAgentMessages() -> [[String: String]] {
        var messages: [[String: String]] = []
        for msg in agentMessages.suffix(20) {
            messages.append(contentsOf: msg.toAIMessages())
        }
        return messages
    }

    private func requestConfirmation(command: String, riskLevel: PendingCommand.RiskLevel) async -> Bool {
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

    private func withTimeout<T: Sendable>(
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
            You are a terminal assistant embedded in an SSH client.
            Answer concisely. Use markdown formatting:
            - Use fenced code blocks (triple backticks with bash) for commands
            - Use bold for emphasis
            - Use inline code for file paths and flags
            No greetings or filler. Match the user's language.
            """
        case .edit:
            """
            You are a terminal assistant embedded in an SSH client.
            The user wants you to suggest a terminal command.
            Provide the command in a fenced code block (triple backticks with bash).
            Explain briefly what it does. Be concise. Match the user's language.
            """
        case .agent:
            AgentPrompts.systemPrompt
        }
    }
}
