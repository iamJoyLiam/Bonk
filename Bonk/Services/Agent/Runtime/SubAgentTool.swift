//
//  SubAgentTool.swift
//  Bonk
//
//  Hand a job to a sub-agent.
//

import Foundation
import os

/// The tools a sub-agent may use.
///
/// The list is the app's, not the host's. A definition on the host *asks*
/// for tools; what a sub-agent actually gets is the intersection of that
/// ask and this list — and the tool that spawns sub-agents is not on it, so
/// a sub-agent cannot spawn a sub-agent. The depth limit is structural, not
/// a check somebody can forget.
enum SubAgentToolSet {

    /// Every tool a sub-agent may have.
    static let allowedToolNames: [String] = [
        BashRunTool.toolName,
        ReadFileTool.toolName,
        SearchHistoryTool.toolName,
        InspectSystemTool.toolName,
        ListDirectoryTool.toolName,
        SkillTool.toolName,
    ]

    /// The tools a definition that names none gets.
    ///
    /// The read-only ones. A definition that says nothing about its tools
    /// gets the safe end of the range, not the empty one: a sub-agent with
    /// no tools cannot do anything, and a definition is written by someone
    /// who may not have thought about it.
    static let readOnlyToolNames: [String] = [
        ReadFileTool.toolName,
        SearchHistoryTool.toolName,
        InspectSystemTool.toolName,
        ListDirectoryTool.toolName,
    ]

    /// The registry a sub-agent runs with.
    ///
    /// Only the named tools, and only the ones this app has.
    static func registry(for names: [String]) -> AgentToolRegistry {
        let wanted = Set(names.filter { allowedToolNames.contains($0) })
        var tools: [any AgentTool] = []
        if wanted.contains(BashRunTool.toolName) { tools.append(BashRunTool()) }
        if wanted.contains(ReadFileTool.toolName) { tools.append(ReadFileTool()) }
        if wanted.contains(SearchHistoryTool.toolName) { tools.append(SearchHistoryTool()) }
        if wanted.contains(InspectSystemTool.toolName) { tools.append(InspectSystemTool()) }
        if wanted.contains(ListDirectoryTool.toolName) { tools.append(ListDirectoryTool()) }
        if wanted.contains(SkillTool.toolName) { tools.append(SkillTool()) }
        return AgentToolRegistry(tools: tools)
    }
}

/// How many sub-agents one run may spawn.
///
/// A cap, and not the only bound: the run's own iteration budget and the
/// sub-agent's own iteration cap bound the rest. But those bounds are about
/// *work*; this one is about *fan-out*, and a model that decides to spawn
/// four sub-agents to answer one question should be told no.
final class SubAgentSpawnBudget: @unchecked Sendable {
    private let limit: Int
    private let used = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    init(limit: Int = SubAgentTool.defaultSpawnLimit) {
        self.limit = limit
    }

    /// Take one slot. False when the run is out.
    func take() -> Bool {
        used.withLock { current in
            guard current < limit else { return false }
            current += 1
            return true
        }
    }

    /// How many have been spawned.
    var count: Int { used.withLock { $0 } }
}

/// A policy that cannot ask.
///
/// A sub-agent runs inside the main agent's turn, and there is nobody to
/// ask: the permission dialog belongs to the outer run. So a command that
/// would need the user's approval is **refused** here, with a reason that
/// tells the sub-agent to hand it back — the main agent can run it itself,
/// through the ordinary path, where the user does see it.
///
/// The base policy still decides everything else. Read-only commands run,
/// critical ones stay blocked, and a command the user has already
/// authorised for this host still runs: that authorisation was the user's
/// own, and it does not expire because the caller changed.
struct SubAgentPermissionPolicy: AgentPermissionPolicy {
    let base: any AgentPermissionPolicy

    func evaluate(tool: String, arguments: [String: String]) -> PermissionDecision {
        switch base.evaluate(tool: tool, arguments: arguments) {
        case .allowed:
            return .allowed
        case let .blocked(reason):
            return .blocked(reason: reason)
        case let .confirmRequired(_, description):
            return .blocked(reason: """
            \(description) — a sub-agent cannot ask the user for approval. \
            Report it back so the main agent can run it itself, where the \
            user will be asked.
            """)
        }
    }
}

/// Hand a job to a sub-agent.
///
/// The sub-agent runs its own loop, with its own context, against the same
/// host. What comes back is its report — model-written text derived from
/// whatever it read, so it is data like any other tool output and travels
/// to the parent in the untrusted envelope.
struct SubAgentTool: AgentTool {
    static let toolName = "task"

    let name = toolName
    let description = """
    Hand a job to a sub-agent on this host. A sub-agent is a specialised \
    worker the user keeps here: it runs on its own, with its own context, \
    and reports back with what it found. Use one for a job that would \
    otherwise fill this conversation with output you do not need to read \
    yourself. Pass the sub-agent's name exactly as it was listed, and the \
    job in the prompt.
    """

    /// The model the sub-agent talks to.
    let gateway: any AgentModelGateway

    /// The policy the sub-agent's calls are judged by.
    let permissionPolicy: any AgentPermissionPolicy

    /// The budget the sub-agent spends from.
    ///
    /// The parent's, not one of its own: the sub-agent spends the user's
    /// money on the same model, and a cap that cannot see the spending
    /// cannot stop it.
    let budget: AgentBudget

    /// How many sub-agents this run may still spawn.
    let spawnBudget: SubAgentSpawnBudget

    /// How many rounds a sub-agent gets.
    static let defaultMaxIterations = 8

    /// How many sub-agents one run may spawn.
    static let defaultSpawnLimit = 4

    /// How much of a report comes back.
    ///
    /// A report is meant to be read by the main agent, not to be a log.
    /// Beyond this the main agent should ask again with a narrower job.
    static let maxReportChars = 8_000

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "agent": {
                  "type": "string",
                  "description": "The sub-agent's name, exactly as it was listed."
                },
                "prompt": {
                  "type": "string",
                  "description": "The job for the sub-agent: what it should find out or do."
                }
              },
              "required": ["agent", "prompt"]
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @escaping @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let agentName = arguments["agent"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !agentName.isEmpty
        else {
            return ("Error: Missing 'agent' argument", 1)
        }
        guard let prompt = arguments["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else {
            return ("Error: Missing 'prompt' argument", 1)
        }
        guard let safeName = RemoteSubAgents.validatedName(agentName) else {
            return ("Error: '\(agentName)' is not a valid sub-agent name", 1)
        }

        // The definition is read from the host, by the app, when the
        // sub-agent is called — not up front for the whole library.
        guard let command = RemoteSubAgents.readCommand(forAgent: safeName) else {
            return ("Error: '\(safeName)' is not a valid sub-agent name", 1)
        }
        let definition: String
        do {
            let result = try await executor(command, nil)
            guard result.exitCode == 0 else {
                return ("Error: the sub-agent '\(safeName)' could not be read on this host", 1)
            }
            definition = result.output
        } catch {
            return ("Error: the sub-agent '\(safeName)' could not be read on this host", 1)
        }

        let body = MarkdownFrontmatter.body(of: definition)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("Error: the sub-agent '\(safeName)' has no instructions", 1)
        }
        let toolNames = RemoteSubAgents.toolNames(from: definition)

        let runtime = AgentRuntime(
            contextProvider: DefaultAgentContextProvider(),
            modelGateway: gateway,
            toolRegistry: SubAgentToolSet.registry(for: toolNames),
            permissionPolicy: SubAgentPermissionPolicy(base: permissionPolicy),
            executionManager: executionManager,
            maxIterations: Self.defaultMaxIterations,
            budget: budget,
            procedure: RemoteSubAgents.procedureMessage(body),
            systemPrompt: AgentPrompts.subAgentSystemPrompt + "\n\n" + RemoteTerminalState.trustPolicy,
            mayRequestApproval: false
        )

        let report = await run(
            runtime: runtime,
            executor: executor,
            task: prompt
        )
        guard !report.isEmpty else {
            return ("Error: the sub-agent '\(safeName)' reported nothing", 1)
        }
        let trimmed = report.count > Self.maxReportChars
            ? String(report.prefix(Self.maxReportChars)) + "\n[report truncated]"
            : report
        return ("[sub-agent: \(safeName)]\n\(trimmed)", 0)
    }

    /// Run the sub-agent's loop and collect what it said last.
    private func run(
        runtime: AgentRuntime,
        executor: @escaping @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32),
        task: String
    ) async -> String {
        var report = ""
        var deltas = ""
        for await event in runtime.run(input: task, executor: executor) {
            switch event {
            case let .assistantText(text):
                report = text
                deltas = ""
            case let .assistantTextDelta(delta):
                deltas += delta
                report = deltas
            case .toolCallStarted:
                // A turn that asks for tools is over; the next one starts
                // the answer we want.
                deltas = ""
            default:
                break
            }
        }
        return report
    }
}
