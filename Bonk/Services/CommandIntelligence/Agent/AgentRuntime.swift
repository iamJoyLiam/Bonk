//  AgentRuntime.swift
//  Bonk — Agent Runtime: Planner→Gate→Executor→Observer→Replan/Cancel/Fail (P0 scaffolding)
//  Workspace isolated behind capabilities, never directly PTY.

import Foundation

enum AgentState: Sendable { case idle, planning, awaitingApproval, executing, observing, done, failed(String), cancelled }

struct WorkspaceAgentPlan: Sendable {
    let steps: [WorkspaceAgentStep]
    struct WorkspaceAgentStep: Sendable, Identifiable {
        let id: UUID
        let command: String
        let requiresApproval: Bool
        let description: String
        init(command: String, requiresApproval: Bool = false, description: String = "") {
            self.id = UUID(); self.command = command; self.requiresApproval = requiresApproval; self.description = description
        }
    }
}

@MainActor
@Observable
final class AgentRuntime {
    private(set) var state: AgentState = .idle
    private let executionBoundary = ExecutionBoundary()
    private let gate = ApprovalGate()

    func run(snapshot: CommandContextSnapshot, goal: String) async {
        state = .planning
        let plan = await plan(for: goal, snapshot: snapshot)
        guard !plan.steps.isEmpty else { state = .failed("Empty plan"); return }

        for step in plan.steps {
            if Task.isCancelled { state = .cancelled; return }
            let req = CommandExecutionRequest(
                id: step.id,
                command: step.command,
                snapshot: snapshot,
                workspace: .local
            )
            if step.requiresApproval {
                state = .awaitingApproval
                let ok = await gate.requestApproval(for: req)
                guard ok else { state = .cancelled; return }
            }
            state = .executing
            do {
                let output = try await executionBoundary.submit(req)
                state = .observing
                let shouldContinue = await observe(output: output, step: step, snapshot: snapshot)
                if !shouldContinue { state = .done; return }
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
        state = .done
    }

    func cancel() { state = .cancelled }

    // MARK: - Planner stub (LLM in P1, rule-based now)

    private func plan(for goal: String, snapshot: CommandContextSnapshot) async -> WorkspaceAgentPlan {
        let commands = goal.components(separatedBy: "&&").flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let steps = commands.map { cmd in
            WorkspaceAgentPlan.WorkspaceAgentStep(
                command: cmd,
                requiresApproval: cmd.lowercased().hasPrefix("sudo") || cmd.contains("rm -rf"),
                description: cmd
            )
        }
        return WorkspaceAgentPlan(steps: steps)
    }

    private func observe(output: String, step: WorkspaceAgentPlan.WorkspaceAgentStep, snapshot: CommandContextSnapshot) async -> Bool {
        // P0: always continue; P1: LLM replan on error
        return true
    }
}
