import Combine
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
    private let streamThrottler = StreamThrottler(throttleMs: 100)
    private var streamCancellable: AnyCancellable?
    private var lastUIUpdate = Date.distantPast

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
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

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

    /// Run the agent: generate plan → wait for approval → execute steps → report.
    func runAgent(
        input: String,
        sshService: SSHNetworkService,
        conversation: AIConversationRecord? = nil,
        context: ModelContext? = nil
    ) async {
        appendAgentMessage(.user, content: input, conversation: conversation, context: context)

        // Phase 1: Generate plan
        guard let plan = await generatePlan(
            input: input, sshService: sshService,
            conversation: conversation, context: context
        ) else { return }

        // If no steps (pure Q&A), just return
        if plan.steps.isEmpty { return }

        // Phase 2: Wait for user approval
        let approved = await requestPlanApproval(plan: plan)
        guard approved else {
            appendAgentMessage(.system, content: "Plan rejected.", conversation: conversation, context: context)
            return
        }

        // Phase 3: Execute steps
        let report = await executePlan(
            plan: plan, sshService: sshService,
            conversation: conversation, context: context
        )

        // Phase 4: Report
        appendExecutionReport(report, conversation: conversation, context: context)
    }

    // MARK: - Phase 1: Generate Plan

    private func generatePlan(
        input _: String,
        sshService _: SSHNetworkService,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async -> AgentPlan? {
        let aiMessages = buildAgentMessages()
        guard let (provider, apiKey) = resolveProvider() else {
            appendAgentMessage(.system, content: lastError ?? "No provider",
                               conversation: conversation, context: context)
            return nil
        }

        let prompt = aiMessages.map { "\($0["role"] ?? "user"): \($0["content"] ?? "")" }
            .joined(separator: "\n\n")
        let systemPrompt = CustomInstructions.buildSystemPrompt(base: AgentPrompts.planPrompt)

        let response: String
        do {
            response = try await executeNonStreaming(
                provider: provider, apiKey: apiKey,
                systemPrompt: systemPrompt, userPrompt: prompt
            )
        } catch {
            appendAgentMessage(.system, content: "AI error: \(error.localizedDescription)",
                               conversation: conversation, context: context)
            return nil
        }

        let sanitized = sanitizer.sanitize(response)
        let parsed = ResponseParser.parsePlan(sanitized)

        // Build plan steps with risk classification
        let steps = parsed.steps.map { step in
            AgentPlan.Step(
                description: step.desc,
                command: step.cmd,
                riskLevel: CommandSafety.classify(step.cmd)
            )
        }

        let plan = AgentPlan(thinking: parsed.thinking, steps: steps, summary: parsed.response)

        // Show plan to user
        appendAgentMessage(.assistant, content: parsed.response,
                           thinking: parsed.thinking, conversation: conversation, context: context)

        return plan
    }

    // MARK: - Phase 2: Plan Approval

    var currentPlan: AgentPlan?

    private func requestPlanApproval(plan: AgentPlan) async -> Bool {
        currentPlan = plan
        return await withCheckedContinuation { continuation in
            planApprovalContinuation = continuation
        }
    }

    var planApprovalContinuation: CheckedContinuation<Bool, Never>?

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

    // MARK: - Phase 3: Execute Plan

    private func executePlan(
        plan: AgentPlan,
        sshService: SSHNetworkService,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async -> ExecutionReport {
        var results: [StepResult] = []
        let startTime = Date()

        for (index, step) in plan.steps.enumerated() {
            guard !Task.isCancelled else {
                appendAgentMessage(.system, content: "Cancelled at step \(index + 1)/\(plan.steps.count).",
                                   conversation: conversation, context: context)
                break
            }

            // Show progress
            appendAgentMessage(.system, content: "Step \(index + 1)/\(plan.steps.count): \(step.description)",
                               conversation: conversation, context: context)

            // Safety check
            if step.riskLevel == .blocked {
                appendAgentMessage(.system, content: "Blocked: \(step.command)",
                                   conversation: conversation, context: context)
                results.append(StepResult(step: step, output: "Blocked", success: false, duration: 0))
                continue
            }

            // Confirmation for moderate/dangerous
            if !step.isAutoExecutable {
                let riskLevel: PendingCommand.RiskLevel = step.riskLevel == .dangerous ? .dangerous : .moderate
                let confirmed = await requestConfirmation(command: step.command, riskLevel: riskLevel)
                guard confirmed else {
                    appendAgentMessage(.system, content: "Skipped: \(step.command)",
                                       conversation: conversation, context: context)
                    results.append(StepResult(step: step, output: "Skipped by user", success: false, duration: 0))
                    continue
                }
            }

            // Execute
            let stepStart = Date()
            do {
                let output = try await withTimeout(seconds: 30) {
                    try await sshService.executeCommand(step.command)
                }
                let truncated = String(output.prefix(4000))
                let duration = Date().timeIntervalSince(stepStart)
                appendAgentMessage(.commandOutput, content: truncated,
                                   conversation: conversation, context: context)
                OperationLog.shared.record(command: step.command, output: truncated, success: true)
                results.append(StepResult(step: step, output: truncated, success: true, duration: duration))
            } catch {
                let errorMsg = "Failed: \(error.localizedDescription)"
                let duration = Date().timeIntervalSince(stepStart)
                appendAgentMessage(.system, content: errorMsg,
                                   conversation: conversation, context: context)
                OperationLog.shared.record(command: step.command, output: errorMsg, success: false)
                results.append(StepResult(step: step, output: errorMsg, success: false, duration: duration))
            }
        }

        let totalTime = Date().timeIntervalSince(startTime)
        return ExecutionReport(results: results, totalTime: totalTime)
    }

    // MARK: - Phase 4: Execution Report

    private func appendExecutionReport(
        _ report: ExecutionReport,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) {
        var lines = ["## Execution Report", ""]

        for (i, result) in report.results.enumerated() {
            let icon = result.success ? "✅" : "❌"
            let duration = String(format: "%.1fs", result.duration)
            lines.append("\(icon) Step \(i + 1): `\(result.step.command)` (\(duration))")
            if !result.success {
                lines.append("   Error: \(result.output.prefix(200))")
            }
        }

        lines.append("")
        lines.append("Total: \(report.successCount)/\(report.totalCount) succeeded, \(report.failureCount) failed, \(String(format: "%.1f", report.totalTime))s")

        appendAgentMessage(.system, content: lines.joined(separator: "\n"),
                           conversation: conversation, context: context)
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
            You are a strictly technical SSH terminal assistant for a native macOS client.

            ## OUTPUT RULES (STRICTLY ENFORCED)
            1. Direct answers only. No greetings, no filler.
            2. All executable shell commands MUST be combined into a SINGLE fenced code block.
            3. Format: ```bash\n<commands>\n```
            4. Comments MUST be on the same line as the command using `#`.
            5. NEVER use numbered lists or bullet points INSIDE the code block.
            6. Explanations MUST be placed OUTSIDE the code block. Use standard Markdown lists for explanations if needed.

            Example:
            ```bash
            docker network create mynet # Create bridge network
            docker run -d --name nginx --network mynet nginx # Start container
            ```
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
