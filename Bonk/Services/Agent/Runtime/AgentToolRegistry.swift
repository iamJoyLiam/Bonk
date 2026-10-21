//
//  AgentToolRegistry.swift
//  Bonk
//
//  Created for P1.5 Agent Runtime Architecture.
//

import Foundation

/// Protocol for an executable agent tool.
protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var definition: LLMToolDefinition { get }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32)
}

/// Standard shell command runner tool.
struct BashRunTool: AgentTool {
    let name = "run_command"
    let description = "Run a shell command on the target system and return stdout/stderr and exit code."

    init() {}

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "command": {
                  "type": "string",
                  "description": "The exact shell command to execute."
                }
              },
              "required": ["command"]
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let command = arguments["command"]?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return ("Error: Missing 'command' argument", 1)
        }

        return try await executor(command) { handle in
            await executionManager.registerActive(handle)
        }
    }
}

/// File reader tool with output guarding.
struct ReadFileTool: AgentTool {
    let name = "read_file"
    let description = "Read content from a file at the specified path."

    init() {}

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "path": {
                  "type": "string",
                  "description": "File path to inspect."
                }
              },
              "required": ["path"]
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let path = arguments["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return ("Error: Missing 'path' argument", 1)
        }
        let safePath = path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "head -n 200 '\(safePath)' 2>/dev/null || cat '\(safePath)'"
        return try await executor(cmd) { handle in
            await executionManager.registerActive(handle)
        }
    }
}

/// Command history search tool.
struct SearchHistoryTool: AgentTool {
    let name = "search_history"
    let description = "Search command history for previous commands matching a query."

    init() {}

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "query": {
                  "type": "string",
                  "description": "Keyword to search within command history."
                }
              },
              "required": ["query"]
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let query = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: Missing 'query' argument", 1)
        }
        let safeQuery = query.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "fc -ln -1000 2>/dev/null | grep -i '\(safeQuery)' | tail -n 25 || history | grep -i '\(safeQuery)' | tail -n 25"
        return try await executor(cmd) { handle in
            await executionManager.registerActive(handle)
        }
    }
}

/// System state inspection tool.
struct InspectSystemTool: AgentTool {
    let name = "inspect_system"
    let description = "Inspect remote system state including OS, uptime, memory, and disk usage."

    init() {}

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {},
              "required": []
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        let cmd = "echo '--- OS ---'; uname -a; echo '--- UPTIME ---'; uptime; echo '--- MEMORY ---'; free -h 2>/dev/null || vm_stat; echo '--- DISK ---'; df -h /"
        return try await executor(cmd) { handle in
            await executionManager.registerActive(handle)
        }
    }
}

/// Directory listing tool with details.
struct ListDirectoryTool: AgentTool {
    let name = "list_dir"
    let description = "List files and subdirectories with details (permissions, owner, size, date)."

    init() {}

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "path": {
                  "type": "string",
                  "description": "Path to directory to list. Defaults to current directory if omitted."
                }
              },
              "required": []
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        let target = arguments["path"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "."
        let safeTarget = (target.isEmpty ? "." : target).replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "ls -la '\(safeTarget)'"
        return try await executor(cmd) { handle in
            await executionManager.registerActive(handle)
        }
    }
}

/// Thread-safe registry containing declared tools available to the Agent.


/// Load a procedure the user keeps on the connected host.
///
/// The name comes from the model, so it is untrusted input on its way to
/// a path: `RemoteSkills.path(forSkill:)` accepts only names that cannot
/// walk out of the skills directory.
struct SkillTool: AgentTool {
    static let toolName = "skill"
    let name = toolName
    let description = """
    Load a procedure the user keeps on this host. Use it when a task calls     for one of the skills listed in the context. Pass the skill's name.
    """

    init() {}

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "description": "The skill's name, exactly as it was listed."
                }
              },
              "required": ["name"]
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let skillName = arguments["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skillName.isEmpty
        else {
            return ("Error: Missing 'name' argument", 1)
        }
        guard let command = RemoteSkills.readCommand(forSkill: skillName) else {
            return ("Error: '\(skillName)' is not a valid skill name", 1)
        }
        let result = try await executor(command) { handle in
            await executionManager.registerActive(handle)
        }
        guard result.exitCode == 0, !result.output.isEmpty else {
            return ("Error: no skill named '\(skillName)' on this host", 1)
        }
        return (result.output, 0)
    }
}

/// The task list tool.
///
/// The model writes its own checklist: what it is about to do, what it has
/// done, and what it is doing right now. The list is the state the model
/// can read — without it the model has to infer its position from the
/// transcript.
///
/// The tool needs no permission and runs nothing. It writes to the run's
/// store and returns the list, which is the model reading back its own
/// plan. The content is the model's own words, so it comes back as an
/// ordinary tool result: the same trust class as any other tool output.
struct TodoWriteTool: AgentTool {
    static let toolName = "todo_write"

    let name = toolName
    let description = """
    Record the task list for the current job. Use it for work that takes     three or more distinct steps, and keep it current: write the whole list     again with one item marked in_progress, and again with it marked     completed. Exactly one item should be in_progress at a time. Skip it     for a single straightforward task.
    """

    /// Where the list is kept.
    let store: AgentTodoStore

    init(store: AgentTodoStore) {
        self.store = store
    }

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: """
            {
              "type": "object",
              "properties": {
                "todos": {
                  "type": "array",
                  "description": "The complete task list, replacing the previous one.",
                  "items": {
                    "type": "object",
                    "properties": {
                      "content": {
                        "type": "string",
                        "description": "The task, stated as a short imperative."
                      },
                      "status": {
                        "type": "string",
                        "enum": ["pending", "in_progress", "completed"],
                        "description": "Where the task stands."
                      },
                      "activeForm": {
                        "type": "string",
                        "description": "The task in present continuous form, e.g. 'Checking disk usage'."
                      }
                    },
                    "required": ["content", "status"]
                  }
                }
              },
              "required": ["todos"]
            }
            """
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let raw = arguments["todos"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ("Error: Missing 'todos' argument", 1)
        }
        guard let items = Self.parse(raw) else {
            return (
                "Error: 'todos' must be a JSON array of items, each with a 'content' string and a 'status' of pending, in_progress or completed.",
                1
            )
        }
        await store.replace(with: items)
        return (Self.render(items), 0)
    }

    /// Parse the list the model wrote.
    ///
    /// Pure, because the model writes this: it can be anything, and a
    /// malformed list has to be reported rather than crash the run.
    static func parse(_ raw: String) -> [AgentTodoItem]? {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var items: [AgentTodoItem] = []
        for entry in array {
            guard let content = entry["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let statusText = entry["status"] as? String
            else { return nil }
            let activeForm = (entry["activeForm"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(AgentTodoItem(
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                status: AgentTodoItem.Status(modelText: statusText),
                activeForm: (activeForm?.isEmpty == false) ? activeForm : nil
            ))
        }
        return items
    }

    /// Render the list the model reads back.
    static func render(_ items: [AgentTodoItem]) -> String {
        guard !items.isEmpty else { return "Task list cleared." }
        let lines = items.enumerated().map { index, item in
            let mark = switch item.status {
            case .completed: "x"
            case .inProgress: "~"
            case .pending: " "
            }
            return "\(index + 1). [\(mark)] \(item.content)"
        }
        return "Task list updated (\(items.count) items):\n" + lines.joined(separator: "\n")
    }
}

final class AgentToolRegistry: @unchecked Sendable {
    private var tools: [String: any AgentTool] = [:]
    private let lock = NSLock()

    /// Where the model's task list is kept.
    ///
    /// The registry owns it because the tool and the runtime both need it,
    /// and the runtime has no other handle on the tools it holds.
    let todoStore: AgentTodoStore

    init(tools: [any AgentTool]? = nil, todoStore: AgentTodoStore = AgentTodoStore()) {
        self.todoStore = todoStore
        let registered = tools ?? [
            BashRunTool(),
            ReadFileTool(),
            SearchHistoryTool(),
            InspectSystemTool(),
            ListDirectoryTool(),
            TodoWriteTool(store: todoStore),
            SkillTool()
        ]
        for tool in registered {
            self.tools[tool.name] = tool
        }
    }

    func register(_ tool: any AgentTool) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.name] = tool
    }

    func tool(named name: String) -> (any AgentTool)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    var definitions: [LLMToolDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tools.values).map(\.definition)
    }
}
