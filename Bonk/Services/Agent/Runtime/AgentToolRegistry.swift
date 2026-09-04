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
        executor: @Sendable (String, (@Sendable (any CommandExecutionHandle) -> Void)?) async throws -> (output: String, exitCode: Int32)
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
        executor: @Sendable (String, (@Sendable (any CommandExecutionHandle) -> Void)?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let command = arguments["command"]?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return ("Error: Missing 'command' argument", 1)
        }

        return try await executor(command) { handle in
            Task {
                await executionManager.registerActive(handle)
            }
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
        executor: @Sendable (String, (@Sendable (any CommandExecutionHandle) -> Void)?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let path = arguments["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return ("Error: Missing 'path' argument", 1)
        }
        let safePath = path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "head -n 200 '\(safePath)' 2>/dev/null || cat '\(safePath)'"
        return try await executor(cmd) { handle in
            Task {
                await executionManager.registerActive(handle)
            }
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
        executor: @Sendable (String, (@Sendable (any CommandExecutionHandle) -> Void)?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        guard let query = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: Missing 'query' argument", 1)
        }
        let safeQuery = query.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "fc -ln -1000 2>/dev/null | grep -i '\(safeQuery)' | tail -n 25 || history | grep -i '\(safeQuery)' | tail -n 25"
        return try await executor(cmd) { handle in
            Task {
                await executionManager.registerActive(handle)
            }
        }
    }
}

/// Thread-safe registry containing declared tools available to the Agent.
final class AgentToolRegistry: @unchecked Sendable {
    private var tools: [String: any AgentTool] = [:]
    private let lock = NSLock()

    init(tools: [any AgentTool] = [BashRunTool(), ReadFileTool(), SearchHistoryTool()]) {
        for tool in tools {
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
