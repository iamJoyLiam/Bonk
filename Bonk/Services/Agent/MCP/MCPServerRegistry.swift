//
//  MCPServerRegistry.swift
//  Bonk
//
//  The MCP servers this app talks to, and the tools they offer.
//
//  The servers are started once and kept alive for as long as the app
//  runs: an MCP server is a program that wants a pipe, and starting one
//  per agent run would mean paying for the handshake every time.
//
//  **A server that does not come up costs its own tools and nothing
//  else.** One broken server -- a command that does not exist, a server
//  that crashes on startup -- must not stop the other servers, and must
//  not stop the agent from running.
//
//  **A server that requires OAuth but cannot be authenticated is skipped
//  the same way.** The user is notified, but the agent keeps running.
//
//  **A tool whose name is not a name is not registered.** The tool list
//  comes from the server, and a name is the one thing in it that ends
//  up in front of the model.
//

import Foundation
import os

/// The MCP servers this app talks to.
@MainActor
final class MCPServerRegistry {
    private static let logger = Logger(subsystem: "com.bonk", category: "MCP")

    /// The servers the app shares.
    static let shared = MCPServerRegistry()

    private var clients: [String: MCPClient] = [:]
    private var transports: [String: MCPTransport] = [:]
    private var tools: [any AgentTool] = []
    private var started = false

    /// The authentication manager for OAuth flows.
    private let authManager: MCPAuthenticationManager

    init(authManager: MCPAuthenticationManager = MCPAuthenticationManager()) {
        self.authManager = authManager
    }

    deinit {
        for transport in transports.values {
            Task { await transport.close() }
        }
    }

    /// The tools the servers offer, ready to be registered.
    var agentTools: [any AgentTool] { tools }

    /// The servers that are running.
    var runningServerNames: [String] { clients.keys.sorted() }

    /// Start the configured servers and collect their tools.
    ///
    /// Calling it again does nothing: the servers are already up.
    func start(configurations: [MCPServerConfiguration]? = nil) async {
        guard !started else { return }
        started = true

        let configurations = configurations ?? MCPServerConfigurationStore.load()
        guard !configurations.isEmpty else { return }

        for configuration in configurations {
            await startServer(configuration)
        }
    }

    /// Start one server and collect its tools.
    private func startServer(_ configuration: MCPServerConfiguration) async {
        // If the server requires OAuth, authenticate first.
        var bearerToken: String?
        if let oauth = configuration.oauth {
            let result = await authManager.authorize(server: configuration)
            switch result {
            case .authorized:
                bearerToken = authManager.accessToken(for: configuration.name)
            case .refused:
                Self.logger.info(
                    "MCP server '\(configuration.name, privacy: .public)' authorization was declined by the user; skipping"
                )
                return
            case .failed(let error):
                Self.logger.error(
                    "MCP server '\(configuration.name, privacy: .public)' OAuth failed: \(error)"
                )
                return
            }
        }

        let transport: MCPTransport
        if let command = configuration.command {
            // Stdio transport
            let stdioConfig = MCPStdioTransport.Configuration(
                command: command,
                arguments: configuration.arguments,
                environment: configuration.environment,
                workingDirectory: configuration.workingDirectory,
                bearerToken: bearerToken
            )
            transport = MCPStdioTransport(configuration: stdioConfig)
        } else if let endpointURL = configuration.endpointURL {
            // HTTP transport
            let httpConfig = MCPStreamableHTTPTransport.Configuration(
                endpointURL: endpointURL,
                headers: configuration.headers,
                timeout: configuration.timeout,
                bearerToken: bearerToken
            )
            transport = MCPStreamableHTTPTransport(configuration: httpConfig)
        } else {
            Self.logger.error(
                "MCP server '\(configuration.name, privacy: .public)' has no command or endpoint URL"
            )
            return
        }

        let client = MCPClient(transport: transport)
        do {
            _ = try await client.connect()
            let descriptors = try await client.listTools()
            var accepted = 0
            for descriptor in descriptors {
                guard let toolName = MCPTool.validatedName(descriptor.name) else {
                    Self.logger.error(
                        "The MCP server '\(configuration.name, privacy: .public)' offered a tool with an unusable name; it was not registered"
                    )
                    continue
                }
                tools.append(MCPTool(
                    serverName: configuration.name,
                    toolName: toolName,
                    descriptor: descriptor,
                    client: client
                ))
                accepted += 1
            }
            clients[configuration.name] = client
            transports[configuration.name] = transport
            Self.logger.info(
                "The MCP server '\(configuration.name, privacy: .public)' is up with \(accepted, privacy: .public) tool(s)"
            )
        } catch {
            // A server that will not start is worth saying out loud, and
            // worth nothing more than that.
            Self.logger.error(
                "The MCP server '\(configuration.name, privacy: .public)' did not start: \(error.localizedDescription, privacy: .public)"
            )
            await client.close()
        }
    }

    /// Stop every server.
    ///
    /// The transports are closed directly: the app is on its way out, and
    /// there is no time to await an actor.
    func shutdown() {
        for transport in transports.values {
            Task { await transport.close() }
        }
        transports.removeAll()
        clients.removeAll()
        tools.removeAll()
        started = false
    }
}
