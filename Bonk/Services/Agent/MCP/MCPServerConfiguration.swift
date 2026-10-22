//
//  MCPServerConfiguration.swift
//  Bonk
//
//  Which MCP servers this app talks to.
//
//  The configuration is a local file the user writes:
//
//      ~/.bonk/mcp.json
//
//      {
//        "mcpServers": {
//          "github": {
//            "command": "npx",
//            "args": ["-y", "@modelcontextprotocol/server-github"],
//            "env": { "GITHUB_TOKEN": "…" }
//        }
//        }
//
//  **The file is read outside the agent's run.** It says which programs
//  this app starts, so it is the user's decision and never the model's:
//  nothing the model says can add a server, change a command, or add an
//  environment entry.
//
//  **A broken entry is skipped, not fatal.** One server with a bad
//  command must not take the others down, and must not stop the agent
//  from running at all.
//

import Foundation
import os

/// One configured MCP server.
struct MCPServerConfiguration: Sendable, Equatable {
    /// The name the tools are filed under: `mcp__<name>__<tool>`.
    let name: String
    /// The program to run.
    let command: String
    let arguments: [String]
    /// Extra environment entries for the server.
    let environment: [String: String]
    /// Where the server runs.
    let workingDirectory: String?

    init(
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// The transport this server is reached through.
    var transportConfiguration: MCPStdioTransport.Configuration {
        MCPStdioTransport.Configuration(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}

/// Where the configuration lives and how it is read.
enum MCPServerConfigurationStore {
    private static let logger = Logger(subsystem: "com.bonk", category: "MCP")

    /// The file the configuration is read from.
    static func defaultURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".bonk", isDirectory: true)
            .appendingPathComponent("mcp.json", isDirectory: false)
    }

    /// Every server the configuration names.
    ///
    /// A file that is missing is not an error: most people have no MCP
    /// servers. A file that is broken is a problem with that file, and
    /// it is reported — but the agent still runs.
    static func load(from url: URL? = nil) -> [MCPServerConfiguration] {
        let url = url ?? defaultURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let root = try? MCPJSONCoding.value(from: data) else {
            logger.error("The MCP configuration at \(url.path, privacy: .public) is not readable JSON")
            return []
        }
        return configurations(from: root)
    }

    /// The servers named by a parsed configuration.
    static func configurations(from root: MCPJSONValue) -> [MCPServerConfiguration] {
        let servers = root.objectValue?["mcpServers"]?.objectValue ?? [:]
        var result: [MCPServerConfiguration] = []
        for (name, value) in servers {
            guard let safeName = MCPTool.validatedName(name) else {
                logger.error("Skipping an MCP server with an unusable name")
                continue
            }
            guard let object = value.objectValue else {
                logger.error("Skipping the MCP server '\(safeName, privacy: .public)': its entry is not an object")
                continue
            }
            guard let command = object["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty
            else {
                logger.error("Skipping the MCP server '\(safeName, privacy: .public)': it names no command")
                continue
            }
            let arguments = (object["args"]?.arrayValue ?? []).compactMap(\.stringValue)
            var environment: [String: String] = [:]
            for (key, item) in object["env"]?.objectValue ?? [:] {
                if let text = item.stringValue { environment[key] = text }
            }
            let workingDirectory = object["cwd"]?.stringValue
            result.append(MCPServerConfiguration(
                name: safeName,
                command: command,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            ))
        }
        return result.sorted { $0.name < $1.name }
    }
}
