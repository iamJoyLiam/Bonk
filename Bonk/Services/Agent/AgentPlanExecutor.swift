import Foundation
import SwiftData

/// Handles the Agent mode plan → approve → execute → report flow.
/// Extracted from AgentEngine to reduce file size.
extension AgentEngine {
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

    private func requestPlanApproval(plan: AgentPlan) async -> Bool {
        currentPlan = plan
        return await withCheckedContinuation { continuation in
            planApprovalContinuation = continuation
        }
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

        for (index, result) in report.results.enumerated() {
            let icon = result.success ? "✅" : "❌"
            let duration = String(format: "%.1fs", result.duration)
            lines.append("\(icon) Step \(index + 1): `\(result.step.command)` (\(duration))")
            if !result.success {
                lines.append("   Error: \(result.output.prefix(200))")
            }
        }

        lines.append("")
        let total = "Total: \(report.successCount)/\(report.totalCount) succeeded"
        let failed = "\(report.failureCount) failed"
        let time = String(format: "%.1fs", report.totalTime)
        lines.append("\(total), \(failed), \(time)")

        appendAgentMessage(.system, content: lines.joined(separator: "\n"),
                           conversation: conversation, context: context)
    }
}
