import Foundation
import SwiftData

/// Handles the Agent mode plan → approve → execute → report flow.
/// Extracted from AgentEngine to reduce file size.
extension AgentEngine {
    // MARK: - Agent Mode (Plan → Approve → Execute)

    /// Run the agent: generate plan → wait for approval → execute steps → report.
    func runAgent(
        input: String,
        displayInput: String? = nil,
        sshService: SSHNetworkService,
        hostName: String? = nil,
        conversation: AIConversationRecord? = nil,
        context: ModelContext? = nil
    ) async {
        await runAgent(input: input, displayInput: displayInput, sshService: sshService, hybridSession: nil, hostName: hostName, conversation: conversation, context: context)
    }

    /// v3.3 Hybrid overload — activeTab's TerminalSession provides multiplexed exec.
    func runAgent(
        input: String,
        displayInput: String? = nil,
        sshService: SSHNetworkService,
        hybridSession: TerminalSession?,
        hostName: String? = nil,
        conversation: AIConversationRecord? = nil,
        context: ModelContext? = nil
    ) async {
        let intent = UserIntent.parse(rawInput: displayInput ?? input, defaultExecutionRequested: true)
        appendAgentMessage(.user, content: displayInput ?? input, conversation: conversation, context: context)

        // If user provided context references only (@history, @terminal) without an execution prompt,
        // do not run tool execution loop; perform safe direct synthesis instead.
        if !intent.executionRequested {
            await runAgentDirectSynthesis(
                input: input,
                conversation: conversation,
                context: context
            )
            return
        }

        let useToolLoop = resolveProvider().map { resolved in
            LLMProviderFactory.provider(
                for: resolved.0, apiKey: resolved.1, workload: .agentToolLoop
            )
                .capability.supportsToolCalls
        } ?? false
        if useToolLoop {
            await runAgentToolLoop(
                input: input, sshService: sshService, hybridSession: hybridSession, hostName: hostName,
                conversation: conversation, context: context
            )
        } else {
            await runAgentLegacy(
                input: input, sshService: sshService, hybridSession: hybridSession,
                conversation: conversation, context: context
            )
        }
    }

    /// Direct synthesis when only context references (@history, @terminal) are provided without execution task.
    func runAgentDirectSynthesis(
        input: String,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async {
        guard let (provider, apiKey) = resolveProvider() else {
            appendAgentMessage(.system, content: lastError ?? L.t(.aiNoResponse), conversation: conversation, context: context)
            return
        }
        let llm = LLMProviderFactory.provider(for: provider, apiKey: apiKey, workload: .chat)
        let isGreeting = UserIntent.isGreetingOrConversational(input)
        let systemPrompt = isGreeting
            ? "You are Bonk's AI terminal assistant. The user has sent a greeting or pleasantry. Respond warmly, politely, and concisely in the user's language, introducing how you can help with server inspection, diagnostics, and running terminal commands."
            : "You are a helpful terminal assistant. The user has attached terminal context without requesting command execution. Please analyze and summarize the context concisely, highlighting key findings, command history or system status, and suggest helpful next actions if appropriate."
        let messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(input)
        ]
        do {
            let turn = try await llm.chat(messages: messages, maxTokens: 1024, disableReasoning: false)
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                appendAgentMessage(.assistant, content: text, conversation: conversation, context: context)
            } else {
                appendAgentMessage(.system, content: L.t(.agNoAnomalies), conversation: conversation, context: context)
            }
        } catch {
            appendAgentMessage(.system, content: "AI error: \(error.localizedDescription)", conversation: conversation, context: context)
        }
    }

    // MARK: - Legacy Plan Flow (Claude / Gemini / Ollama / fallback)

    func runAgentLegacy(
        input: String,
        sshService: SSHNetworkService,
        hybridSession: TerminalSession? = nil,
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async {
        // Phase 1: Generate plan
        guard let plan = await generatePlan(
            conversation: conversation, context: context
        ) else { return }

        // If no steps (pure Q&A), just return
        if plan.steps.isEmpty { return }

        // Phase 4 deterministic plan gate: an unexecutable plan (every
        // step blocked) skips the approval UI — there is nothing the user
        // could approve into existence. Reported, not silently dropped.
        if plan.isUnexecutable {
            appendAgentMessage(.system, content: L.t(.agPlanBlocked),
                               conversation: conversation, context: context)
            return
        }

        // Phase 2: Wait for user approval
        let approved = await requestPlanApproval(plan: plan)
        guard approved else {
            appendAgentMessage(.system, content: L.t(.planRejected), conversation: conversation, context: context)
            return
        }

        // Phase 3: Execute steps (v3.3 hybrid)
        let report = await executePlan(
            plan: plan, sshService: sshService, hybridSession: hybridSession,
            conversation: conversation, context: context
        )

        // Phase 4: Report
        appendExecutionReport(report, conversation: conversation, context: context)
    }

    // MARK: - Phase 1: Generate Plan

    private func generatePlan(
        conversation: AIConversationRecord?,
        context: ModelContext?
    ) async -> AgentPlan? {
        let aiMessages = buildAgentMessages()
        guard let (provider, apiKey) = resolveProvider() else {
            appendAgentMessage(.system, content: lastError ?? L.t(.noProvidersConfigured),
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
        hybridSession: TerminalSession? = nil,
        conversation: AIConversationRecord?,
        context: ModelContext?,
        foldEngine: any DecisionEngine = DecisionEngineFactory.makeEffective()
    ) async -> ExecutionReport {
        let hybridExec: (@Sendable (String, CommandHandleRegistration?) async throws -> String)? = if let session = hybridSession {
            { @Sendable command, registerHandle async throws -> String in
                try await session.executeHybrid(command, registerHandle: registerHandle)
            }
        } else { nil }
        var results: [StepResult] = []
        let startTime = Date()
        // Consecutive step failures. Legacy had no failure brake at all —
        // steps ran regardless. The Phase 4 gate below consults it.
        var consecutiveFailures = 0

        for (index, step) in plan.steps.enumerated() {
            guard !Task.isCancelled else {
                appendAgentMessage(.system, content: String(format: L.t(.cancelledAtStep), index + 1),
                                   conversation: conversation, context: context)
                break
            }

            // Show progress
            appendAgentMessage(.system, content: "Step \(index + 1)/\(plan.steps.count): \(step.description)",
                               conversation: conversation, context: context)

            // Safety check
            if step.riskLevel == .blocked {
                appendAgentMessage(.system, content: String(format: L.t(.blockedStep), step.command),
                                   conversation: conversation, context: context)
                results.append(StepResult(step: step, output: "Blocked", success: false, duration: 0))
                continue
            }

            // Confirmation for moderate/dangerous.
            // Phase 2 fold path: same deterministic evaluator as the Runtime
            // tool loop. Folded steps skip the dialog; everything else
            // confirms exactly as before. Folded approvals never train
            // future eligibility — only explicit verdicts are recorded.
            if !step.isAutoExecutable {
                let riskLevel: PendingCommand.RiskLevel = step.riskLevel == .dangerous ? .dangerous : .moderate
                let confirmed: Bool
                if await tryFoldPlanStep(step: step, index: index, engine: foldEngine) {
                    confirmed = true
                } else {
                    let stepKey = CommandNormalizer.normalizedKey(step.command)
                    let stepHistory = await decisionMemory.facts(for: stepKey)
                    let reason = ConfirmationReason.describe(
                        safetyLevel: "L\(step.riskLevel.level.rawValue)", history: stepHistory
                    )
                    confirmed = await requestConfirmation(command: step.command, riskLevel: riskLevel, reasonDetail: reason)
                    await decisionMemory.recordDecision(
                        key: stepKey,
                        decision: confirmed ? .approved : .denied
                    )
                }
                guard confirmed else {
                    appendAgentMessage(.system, content: L.t(.agPlanStopped),
                                       conversation: conversation, context: context)
                    results.append(StepResult(step: step, output: "Cancelled by user", success: false, duration: 0))
                    break
                }
            }

            // Execute (v3.3 hybrid — one connection, many channels)
            let stepStart = Date()
            let sshService = sshService
            let hybridExec = hybridExec
            let command = step.command
            do {
                let output = try await withTimeout(seconds: 30) {
                    if let exec = hybridExec {
                        return try await exec(command) { handle in
                            await AgentExecutionManager.shared.registerActive(handle)
                        }
                    }
                    return try await sshService.executeCommand(command) { handle in
                        await AgentExecutionManager.shared.registerActive(handle)
                    }
                }
                await AgentExecutionManager.shared.clearActive()
                let truncated = String(output.prefix(4000))
                let duration = Date().timeIntervalSince(stepStart)
                consecutiveFailures = 0
                appendAgentMessage(.commandOutput, content: truncated,
                                   conversation: conversation, context: context)
                OperationLog.shared.record(command: step.command, output: truncated, success: true)
                results.append(StepResult(step: step, output: truncated, success: true, duration: duration))
            } catch {
                await AgentExecutionManager.shared.clearActive()
                let errorMsg = Task.isCancelled ? "Command was cancelled by user." : "Failed: \(error.localizedDescription)"
                let duration = Date().timeIntervalSince(stepStart)
                consecutiveFailures += 1
                appendAgentMessage(.system, content: errorMsg,
                                   conversation: conversation, context: context)
                OperationLog.shared.record(command: step.command, output: errorMsg, success: false)
                results.append(StepResult(step: step, output: errorMsg, success: false, duration: duration))
                // Phase 4 post-failure gate: keep going or abort the plan.
                // Errors preserve legacy behavior (continue) — the gate can
                // only add aborts, never remove the old continue path.
                let remaining = plan.steps.count - index - 1
                let shouldContinue = await gatePlanContinue(
                    command: command,
                    consecutiveFailures: consecutiveFailures,
                    remainingSteps: remaining,
                    stepIndex: index,
                    engine: foldEngine
                )
                if !shouldContinue {
                    appendAgentMessage(.system, content: String(format: L.t(.agPlanAborted), consecutiveFailures),
                                       conversation: conversation, context: context)
                    break
                }
            }
        }

        let totalTime = Date().timeIntervalSince(startTime)
        return ExecutionReport(results: results, totalTime: totalTime)
    }

    // MARK: - Phase 2: plan-step confirmation folding

    /// Attempts to fold one plan-step confirmation. Returns true when the
    /// dialog was folded (engine said fold for an eligible step). Returns
    /// false for every other outcome so the caller falls back to the
    /// dialog. Never fails open. Shares the evaluator, gate, and trace
    /// contract with the Runtime tool-loop fold path.
    /// Attempts to fold one plan-step confirmation. `engine` defaults to the
    /// configured effective engine; tests inject stubs. Returns true when
    /// the dialog was folded. Never fails open.
    func tryFoldPlanStep(
        step: AgentPlan.Step,
        index: Int,
        engine: any DecisionEngine = DecisionEngineFactory.makeEffective()
    ) async -> Bool {
        let level = step.riskLevel.level
        let profile = CommandEffectProfiler.profile(command: step.command)
        let key = CommandNormalizer.normalizedKey(step.command)
        await decisionMemory.recordEvaluation(key: key)
        let history = await decisionMemory.facts(for: key)
        let eligibility = ConfirmationFoldEvaluator.check(tool: "run_command", level: level, effect: profile, facts: history)
        guard eligibility.eligible else { return false }

        let tagList = profile.tags.map(\.rawValue).sorted().joined(separator: "+")
        await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
            kind: .confirmationFoldable, engine: engine.engineName, task: "agentPlan",
            result: "eligible-L\(level.rawValue)-\(tagList)-approved×\(history?.allowCount ?? 0)"
        ))
        let (disposition, _) = await ConfirmationFoldGate.evaluate(
            engine: engine,
            facts: FoldGateFacts(
                tool: "run_command",
                normalizedCommand: key,
                safetyLevel: "L\(level.rawValue)",
                accessMode: AgentEngine.accessMode.rawValue,
                semanticTags: tagList,
                previousUserDecision: "approved",
                sameCommandOccurrences: history?.occurrences ?? 0,
                iteration: index
            ),
            threshold: DecisionEngineConfig.load().decisionThreshold,
            task: "agentPlan"
        )
        return disposition == .foldConfirmation
    }

    // MARK: - Decision Phase 4: post-failure continue/abort gate

    /// Asks whether the plan should continue after a step failure.
    /// `engine` defaults to the configured effective engine; tests inject
    /// stubs. First failures always continue without consulting the engine
    /// (a single failure is not a pattern). Engine errors preserve legacy
    /// behavior (continue) — the gate can only add aborts, and aborts only
    /// ever follow consecutive failures. Never fails open into an abort.
    func gatePlanContinue(
        command: String,
        consecutiveFailures: Int,
        remainingSteps: Int,
        stepIndex: Int,
        threshold: Double = DecisionEngineConfig.load().decisionThreshold,
        engine: any DecisionEngine = DecisionEngineFactory.makeEffective()
    ) async -> Bool {
        guard consecutiveFailures > 1 else { return true }
        let task = "agentPlan"
        await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
            kind: .decisionRequested, engine: engine.engineName, task: task, result: "continue-plan"
        ))
        let start = Date()
        do {
            let decision = try await engine.gate(
                question: "continue-plan",
                context: DecisionContext(
                    localConfidence: 0.0,
                    decisionThreshold: threshold,
                    facts: [
                        "normalizedCommand": CommandNormalizer.normalizedKey(command),
                        "consecutiveFailures": "\(consecutiveFailures)",
                        "remainingSteps": "\(remainingSteps)",
                        "stepIndex": "\(stepIndex)",
                    ]
                )
            )
            let latencyMs = Date().timeIntervalSince(start) * 1000
            let shouldContinue = decision.shouldProceed
            await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
                kind: .decisionResolved, engine: engine.engineName, task: task,
                latencyMs: latencyMs, result: shouldContinue ? "continue-plan" : "abort-plan"
            ))
            return shouldContinue
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            await DecisionTraceRecorder.shared.recordAgentEvent(AgentTraceEvent(
                kind: .decisionFallback, engine: engine.engineName, task: task,
                latencyMs: latencyMs, success: false, result: "gate-error"
            ))
            return true
        }
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
