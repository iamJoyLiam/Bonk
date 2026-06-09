import Foundation
import os.log

/// Core Agent session that manages the command → result → AI analysis loop.
@Observable @MainActor
final class AgentSession {
    private static let logger = Logger(subsystem: "com.bonk", category: "Agent")

    let sshService: SSHNetworkService
    let aiService: AIService

    var messages: [AgentMessage] = []
    var isProcessing = false
    var pendingConfirmation: PendingCommand?

    private let maxIterations = 10
    private let maxHistoryMessages = 20
    private let commandTimeout: TimeInterval = 30
    private let maxOutputChars = 4000
    private var currentTask: Task<Void, Never>?

    init(sshService: SSHNetworkService, aiService: AIService = .shared) {
        self.sshService = sshService
        self.aiService = aiService
    }

    // MARK: - Public API

    func run(userInput: String) async {
        messages.append(AgentMessage(role: .user, content: userInput))
        isProcessing = true
        currentTask?.cancel()

        let task = Task { await runLoop() }
        currentTask = task
        await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
        pendingConfirmation = nil
    }

    func clearHistory() {
        messages = []
    }

    // MARK: - Main Loop

    private func runLoop() async {
        defer {
            isProcessing = false
            currentTask = nil
        }

        for _ in 0 ..< maxIterations {
            guard !Task.isCancelled else {
                appendSystem("Cancelled.")
                return
            }

            guard let response = await fetchAIResponse() else { return }
            let parsed = ResponseParser.parse(response)

            messages.append(AgentMessage(
                role: .assistant,
                content: parsed.response,
                command: parsed.command,
                thinking: parsed.thinking
            ))

            guard let command = parsed.command, !command.isEmpty else { return }
            guard await confirmIfNeeded(command: command, response: parsed.response) else { return }
            await executeAndRecord(command: command)
        }

        appendSystem("Reached maximum iterations (\(maxIterations)). Stopping.")
    }

    // MARK: - AI Communication

    private func fetchAIResponse() async -> String? {
        let aiMessages = buildAIMessages()
        do {
            return try await withTimeout(seconds: 60) {
                await self.callAI(messages: aiMessages)
            }
        } catch {
            appendSystem("AI request timed out.")
            return nil
        }
    }

    private func callAI(messages: [[String: String]]) async -> String? {
        guard let provider = aiService.activeProvider, !provider.apiKey.isEmpty else {
            return nil
        }
        let endpoint = resolveEndpoint(provider)
        guard !endpoint.isEmpty else { return nil }

        do {
            return try await AIRequestBuilder.execute(
                provider: provider,
                endpoint: endpoint,
                apiKey: provider.apiKey,
                messages: messages,
                maxTokens: provider.maxOutputTokens ?? 2000
            )
        } catch {
            Self.logger.error("Agent AI request failed: \(error)")
            return nil
        }
    }

    private func resolveEndpoint(_ provider: AIProviderConfig) -> String {
        provider.endpoint.isEmpty ? provider.type.defaultEndpoint : provider.endpoint
    }

    // MARK: - Confirmation

    private func confirmIfNeeded(command: String, response: String) async -> Bool {
        let safety = CommandSafety.classify(command)

        switch safety {
        case .blocked:
            appendSystem("⛔ Command blocked: `\(command)`\nThis command is not allowed.")
            return false
        case .dangerous:
            return await requestConfirmation(command: command, reason: response, riskLevel: .dangerous)
        case .moderate:
            return await requestConfirmation(command: command, reason: response, riskLevel: .moderate)
        case .safe:
            return true
        }
    }

    private func requestConfirmation(
        command: String,
        reason: String,
        riskLevel: PendingCommand.RiskLevel
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingConfirmation = PendingCommand(
                command: command,
                reason: reason,
                riskLevel: riskLevel,
                continuation: { confirmed in continuation.resume(returning: confirmed) }
            )
        }
    }

    // MARK: - Execution

    private func executeAndRecord(command: String) async {
        do {
            Self.logger.info("Executing: \(command)")
            let output = try await withTimeout(seconds: commandTimeout) {
                try await self.sshService.executeCommand(command)
            }
            let truncated = output.count > maxOutputChars
                ? String(output.prefix(maxOutputChars)) + "\n... (truncated, \(output.count) chars total)"
                : output
            messages.append(AgentMessage(role: .commandOutput, content: truncated))
        } catch is TimeoutError {
            Self.logger.error("Command timed out: \(command)")
            messages.append(AgentMessage(
                role: .commandOutput,
                content: "⏱ Timed out after \(Int(commandTimeout))s: \(command)"
            ))
        } catch {
            Self.logger.error("Command failed: \(error.localizedDescription)")
            messages.append(AgentMessage(
                role: .commandOutput,
                content: "Error: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Helpers

    private func appendSystem(_ text: String) {
        messages.append(AgentMessage(role: .system, content: text))
    }

    private func buildAIMessages() -> [[String: String]] {
        var result: [[String: String]] = []
        result.append(["role": "system", "content": AgentPrompts.systemPrompt])

        for msg in messages.suffix(maxHistoryMessages) {
            result.append(contentsOf: msg.toAIMessages())
        }
        return result
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @Sendable in try await operation() }
            group.addTask { @Sendable in
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
