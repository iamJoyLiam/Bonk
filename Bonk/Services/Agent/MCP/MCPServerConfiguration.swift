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
//          }
//        }
//      }
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
    /// The program to run, for stdio servers.
    let command: String?
    let arguments: [String]
    /// Extra environment entries for the server.
    let environment: [String: String]
    /// Where the server runs, for stdio servers.
    let workingDirectory: String?
    /// The HTTP endpoint, for HTTP servers.
    let endpointURL: URL?
    /// Extra HTTP headers, for HTTP servers.
    let headers: [String: String]
    /// How long a single request/response round-trip may take, for HTTP servers.
    let timeout: TimeInterval
    /// OAuth configuration, if the server requires OAuth.
    let oauth: OAuthServerConfig?

    init(
        name: String,
        command: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        endpointURL: URL? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30,
        oauth: OAuthServerConfig? = nil
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.endpointURL = endpointURL
        self.headers = headers
        self.timeout = timeout
        self.oauth = oauth
    }

    /// Is this server reached over HTTP?
    var isHTTP: Bool {
        endpointURL != nil
    }

    /// Is this server reached over stdio?
    var isStdio: Bool {
        command != nil
    }
}

/// OAuth configuration for one MCP server, from the user's config file.
struct OAuthServerConfig: Sendable, Equatable {
    let authorizationURL: URL
    let tokenURL: URL
    let clientID: String
    let clientSecret: String?
    let scopes: [String]
    let redirectURI: String
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
        guard let serversObject = root.objectValue,
              let servers = serversObject["mcpServers"]?.objectValue
        else { return [] }

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

            // Determine if this is an HTTP or stdio server.
            if let urlString = object["url"]?.stringValue,
               let url = URL(string: urlString)
            {
                var headers: [String: String] = [:]
                if let headersObj = object["headers"]?.objectValue {
                    for (key, value) in headersObj {
                        if let text = value.stringValue {
                            headers[key] = text
                        }
                    }
                }
                let timeout = object["timeout"]?.numberValue ?? 30.0
                let oauth = oauthConfiguration(from: MCPJSONValue.object(object))
                result.append(MCPServerConfiguration(
                    name: safeName,
                    endpointURL: url,
                    headers: headers,
                    timeout: timeout,
                    oauth: oauth
                ))
            } else {
                guard let command = object["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty
                else {
                    logger.error("Skipping the MCP server '\(safeName, privacy: .public)': it names no command")
                    continue
                }
                let arguments = (object["args"]?.arrayValue ?? []).compactMap { $0.stringValue }
                var environment: [String: String] = [:]
                if let envObj = object["env"]?.objectValue {
                    for (key, item) in envObj {
                        if let text = item.stringValue { environment[key] = text }
                    }
                }
                let workingDirectory = object["cwd"]?.stringValue
                let oauth = oauthConfiguration(from: MCPJSONValue.object(object))
                result.append(MCPServerConfiguration(
                    name: safeName,
                    command: command,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    oauth: oauth
                ))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Parse the optional OAuth configuration from a server entry.
    ///
    /// The server entry may carry an `oauth` object:
    ///
    ///     {
    ///       "command": "npx",
    ///       "args": ["-y", "@modelcontextprotocol/server-github"],
    ///       "oauth": {
    ///         "authorizationURL": "https://github.com/login/oauth/authorize",
    ///         "tokenURL": "https://github.com/login/oauth/access_token",
    ///         "clientID": "…",
    ///         "clientSecret": "…",
    ///         "scopes": ["repo", "read:user"],
    ///         "redirectURI": "http://localhost:12345/callback"
    ///       }
    ///     }
    ///
    /// All fields except `clientSecret` are required when `oauth` is present.
    private static func oauthConfiguration(from object: MCPJSONValue) -> OAuthServerConfig? {
        guard let oauth = object.objectValue?["oauth"]?.objectValue else { return nil }
        guard let authURLString = oauth["authorizationURL"]?.stringValue,
              let authURL = URL(string: authURLString)
        else { return nil }
        guard let tokenURLString = oauth["tokenURL"]?.stringValue,
              let tokenURL = URL(string: tokenURLString)
        else { return nil }
        guard let clientID = oauth["clientID"]?.stringValue,
              !clientID.isEmpty
        else { return nil }
        let clientSecret = oauth["clientSecret"]?.stringValue
        let scopes = (oauth["scopes"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let redirectURI = oauth["redirectURI"]?.stringValue ?? ""
        return OAuthServerConfig(
            authorizationURL: authURL,
            tokenURL: tokenURL,
            clientID: clientID,
            clientSecret: clientSecret,
            scopes: scopes,
            redirectURI: redirectURI
        )
    }
}
