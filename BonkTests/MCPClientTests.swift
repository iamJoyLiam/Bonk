//
//  MCPClientTests.swift
//  BonkTests
//
//  The Model Context Protocol client.
//
//  What has to hold:
//
//  1. **The wire is JSON-RPC.** A request goes out, an answer comes
//     back, and the two are matched by the id.
//
//  2. **The handshake is checked.** A server that speaks a version this
//     client does not know is refused, not talked to.
//
//  3. **A server that never answers does not hold the agent's turn.**
//
//  4. **A tool's name is checked** before it is put in front of a model.
//
//  5. **The types the schema asks for are restored** before a call goes
//     out, so a number the model got right does not arrive as text.
//
//  6. **A real subprocess speaks the protocol** — the stdio transport
//     end to end, with a server that is a shell script.
//
//  The tests never open a window and never touch the network: the
//  in-memory transport is the client core's own test harness, and the
//  subprocess test runs `/bin/sh` on a script in a temporary directory.
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("MCP client")
struct MCPClientTests {

    // MARK: - The wire

    @Test("A request survives the round trip")
    func aRequestSurvivesTheRoundTrip() throws {
        let wire = MCPJSONCoding.request(
            id: "7",
            method: MCPMethod.toolsCall,
            params: .object(["name": .string("echo")])
        )
        let text = try MCPJSONCoding.string(from: wire)
        #expect(text.contains("\"jsonrpc\":\"2.0\""))
        #expect(text.contains("\"id\":\"7\""))

        let parsed = try MCPJSONCoding.message(from: text)
        #expect(parsed == .request(
            id: "7",
            method: MCPMethod.toolsCall,
            params: .object(["name": .string("echo")])
        ))
    }

    @Test("An answer is matched by the id it carries")
    func anAnswerIsMatchedByItsID() throws {
        let wire = MCPJSONCoding.response(id: "3", result: .object(["ok": .bool(true)]))
        let parsed = try MCPJSONCoding.message(from: try MCPJSONCoding.string(from: wire))
        #expect(parsed.responseId == "3")
    }

    @Test("A number id and a string id name the same request")
    func theIdentifierIsComparedByItsText() throws {
        // Servers are not always careful to echo the type of the id they
        // were given. A request sent as `1` may come back as `"1"`.
        let numeric = try MCPJSONCoding.message(from: #"{"jsonrpc":"2.0","id":1,"result":null}"#)
        let textual = try MCPJSONCoding.message(from: #"{"jsonrpc":"2.0","id":"1","result":null}"#)
        #expect(numeric.responseId == textual.responseId)
    }

    @Test("A message that is not JSON-RPC is refused")
    func rubbishIsRefused() {
        #expect(throws: MCPJSONCodingError.self) {
            try MCPJSONCoding.message(from: #"{"id":1,"result":null}"#)
        }
        #expect(throws: MCPJSONCodingError.self) {
            try MCPJSONCoding.message(from: #"["not","an","object"]"#)
        }
        #expect(throws: MCPJSONCodingError.self) {
            try MCPJSONCoding.message(from: "not json at all")
        }
    }

    @Test("An error answer carries the server's code")
    func anErrorAnswerCarriesTheCode() throws {
        let wire = MCPJSONCoding.failure(
            id: "1",
            error: MCPJSONRPCError(code: -32601, message: "no such method")
        )
        let parsed = try MCPJSONCoding.message(from: try MCPJSONCoding.string(from: wire))
        #expect(parsed == .failure(id: "1", error: MCPJSONRPCError(code: -32601, message: "no such method")))
    }

    // MARK: - The names

    @Test("A tool name that is not a name is refused")
    func theNameIsChecked() {
        #expect(MCPTool.validatedName("create_issue") == "create_issue")
        #expect(MCPTool.validatedName("list-issues.2") == "list-issues.2")
        // A name ends up in front of a model. Text with spaces, newlines
        // or marks in it is not a name.
        #expect(MCPTool.validatedName("create issue") == nil)
        #expect(MCPTool.validatedName("create\nissue") == nil)
        #expect(MCPTool.validatedName("create; rm -rf /") == nil)
        #expect(MCPTool.validatedName("") == nil)
        #expect(MCPTool.validatedName(String(repeating: "a", count: 65)) == nil)
    }

    @Test("An MCP tool cannot be mistaken for one of the app's own")
    func theNameCannotCollide() {
        let tool = MCPTool(
            serverName: "github",
            toolName: "run_command",
            descriptor: MCPToolDescriptor(name: "run_command", title: nil, description: nil, inputSchema: nil, annotations: nil),
            client: MCPClient(transport: MCPInMemoryTransport())
        )
        #expect(tool.name == "mcp__github__run_command")
        #expect(tool.name != BashRunTool.toolName)
    }

    // MARK: - The arguments

    @Test("The schema's types come back before the call goes out")
    func theTypesComeBack() throws {
        let schema = try MCPJSONCoding.value(from: """
        {
          "type": "object",
          "properties": {
            "count": { "type": "number" },
            "page": { "type": "integer" },
            "dry": { "type": "boolean" },
            "filter": { "type": "object" },
            "name": { "type": "string" }
          }
        }
        """)
        let typed = MCPTool.typedArguments(
            [
                "count": "42",
                "page": "3",
                "dry": "true",
                "filter": #"{"owner":"me"}"#,
                "name": "hello"
            ],
            schema: schema
        )
        #expect(typed["count"] == .number(42))
        #expect(typed["page"] == .number(3))
        #expect(typed["dry"] == .bool(true))
        #expect(typed["filter"] == .object(["owner": .string("me")]))
        #expect(typed["name"] == .string("hello"))
    }

    @Test("An argument with no schema stays text")
    func anArgumentWithNoSchemaStaysText() {
        let typed = MCPTool.typedArguments(["count": "42"], schema: nil)
        #expect(typed["count"] == .string("42"))
    }

    // MARK: - The client

    @Test("The handshake happens and the version is agreed")
    func theHandshakeHappens() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        let seen = FakeMCPServer.answering(transport: server, tools: [])
        let client = MCPClient(transport: transport, handshakeTimeout: 10, callTimeout: 10)
        let result = try await client.connect()

        #expect(result.protocolVersion == MCPProtocol.latestVersion)
        #expect(result.serverInfo.name == "fake")
        #expect(seen.methods.contains(MCPMethod.initialize))
        // The notification the client sends after the handshake is
        // answered by nothing, so the server hears it a moment after the
        // client is done. The wait is bounded: a gate that hangs is
        // worse than a gate that fails.
        #expect(await waitFor(MCPMethod.initialized, on: seen))
        await client.close()
    }

    @Test("A server that speaks an unknown version is refused")
    func anUnknownVersionIsRefused() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        let seen = FakeMCPServer.answering(
            transport: server,
            tools: [],
            protocolVersion: "1999-01-01"
        )
        let client = MCPClient(transport: transport)
        await #expect(throws: MCPClientError.self) {
            try await client.connect()
        }
        #expect(seen.methods.contains(MCPMethod.initialize))
        await client.close()
    }

    @Test("The server's tools are listed")
    func theToolsAreListed() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        let seen = FakeMCPServer.answering(
            transport: server,
            tools: [
                .object([
                    "name": .string("echo"),
                    "description": .string("Echoes the text."),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["text": .object(["type": .string("string")])])
                    ])
                ])
            ]
        )
        let client = MCPClient(transport: transport, handshakeTimeout: 10, callTimeout: 10)
        try await client.connect()
        let tools = try await client.listTools()

        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")
        #expect(tools.first?.description == "Echoes the text.")
        #expect(seen.methods.contains(MCPMethod.toolsList))
        await client.close()
    }

    @Test("A tool is called and its answer comes back")
    func aToolIsCalled() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        let seen = FakeMCPServer.answering(
            transport: server,
            tools: [],
            callResult: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("hello")])])
            ])
        )
        let client = MCPClient(transport: transport, handshakeTimeout: 10, callTimeout: 10)
        try await client.connect()
        let result = try await client.callTool(
            name: "echo",
            arguments: ["text": .string("hello")]
        )

        #expect(result.isError == false)
        #expect(result.textForModel == "hello")
        #expect(seen.methods.contains(MCPMethod.toolsCall))
        await client.close()
    }

    @Test("A tool that fails is the tool's failure, not the call's")
    func aFailingToolIsReportedAsSuch() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        let seen = FakeMCPServer.answering(
            transport: server,
            tools: [],
            callResult: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("no such ticket")])]),
                "isError": .bool(true)
            ])
        )
        let client = MCPClient(transport: transport, handshakeTimeout: 10, callTimeout: 10)
        try await client.connect()
        let result = try await client.callTool(name: "echo", arguments: [:])

        #expect(result.isError)
        #expect(result.textForModel.contains("no such ticket"))
        await client.close()
    }

    @Test("A server's error is reported as the server's error")
    func aServerErrorIsReported() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        let seen = FakeMCPServer.answering(
            transport: server,
            tools: [],
            error: MCPJSONRPCError(code: -32601, message: "no such method")
        )
        let client = MCPClient(transport: transport, handshakeTimeout: 10, callTimeout: 10)
        try await client.connect()
        do {
            _ = try await client.callTool(name: "echo", arguments: [:])
            Issue.record("the call should have failed")
        } catch let error as MCPClientError {
            #expect(error == .serverError(code: -32601, message: "no such method"))
        }
        await client.close()
    }

    @Test("A server that never answers does not hold the turn")
    func aSilentServerDoesNotHoldTheTurn() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        // A server that hears the request and says nothing.
        let silent = Task {
            for await event in server.events {
                guard case .message = event else { continue }
            }
        }
        let client = MCPClient(transport: transport, handshakeTimeout: 1, callTimeout: 1)
        // The wait for the answer is raced against a watchdog, so a
        // client that has no deadline at all fails this test instead of
        // hanging the run.
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await client.connect()
                    return false
                } catch {
                    // The call ended, and it ended by failing: the
                    // deadline is what ended it.
                    return true
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                // The call never ended. The wait did not have a deadline
                // and the watchdog is what stopped it.
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended, "the deadline has to be the thing that ends the wait")
        silent.cancel()
        await client.close()
    }

    @Test("The deadline is what ends a call the server never answers")
    func theDeadlineEndsTheCall() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        // A server that hears the request and says nothing.
        let silent = Task {
            for await event in server.events {
                guard case .message = event else { continue }
            }
        }
        let client = MCPClient(transport: transport, handshakeTimeout: 1, callTimeout: 1)
        let started = Date()
        // The wait is bounded by a watchdog, so a client with no deadline
        // at all fails this test instead of hanging the run.
        let outcome = await withTaskGroup(of: MCPClientError?.self) { group in
            group.addTask {
                do {
                    _ = try await client.connect()
                    return nil
                } catch let error as MCPClientError {
                    return error
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                // The call never ended: the watchdog is what stopped it.
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // The call fails with the deadline, not with a cancellation and
        // not with a transport error: the deadline is what ended it.
        #expect(
            outcome == .timedOut(method: MCPMethod.initialize, seconds: 1),
            "the deadline has to be what ends the wait"
        )
        #expect(
            Date().timeIntervalSince(started) < 5,
            "the deadline has to end the wait on its own"
        )
        silent.cancel()
        await client.close()
    }

    @Test("A connection that dies fails the call that was waiting")
    func aDeadConnectionFailsTheCall() async throws {
        let (transport, server) = MCPInMemoryTransport.connect()
        _ = FakeMCPServer.answering(transport: server, tools: [])
        let client = MCPClient(transport: transport, handshakeTimeout: 1, callTimeout: 1)
        try await client.connect()
        server.terminate(with: MCPTransportClosedError(reason: "the server went away"))
        await #expect(throws: MCPClientError.self) {
            try await client.callTool(name: "echo", arguments: [:])
        }
        await client.close()
    }

    @Test("A request made after the connection died fails at once")
    func aRequestAfterDeathFailsAtOnce() async throws {
        let (inner, server) = MCPInMemoryTransport.connect()
        // The peer died without closing its end, so the write side is
        // still open: the request goes out and nobody answers it. A
        // transport that threw on the write would hide the difference —
        // the request would fail just as fast, for the wrong reason.
        let transport = SwallowingTransport(inner: inner)
        _ = FakeMCPServer.answering(transport: server, tools: [])
        let client = MCPClient(transport: transport, handshakeTimeout: 10, callTimeout: 10)
        try await client.connect()
        server.terminate(with: MCPTransportClosedError(reason: "the server went away"))
        transport.peerDied()
        // The client learns that the connection is gone from the
        // transport's end event; wait until it has seen it, so the
        // request below is made against a known-dead connection.
        let deadline = Date().addingTimeInterval(2)
        while await !client.connectionIsDead, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.connectionIsDead, "the client has to learn that the connection is gone")

        let started = Date()
        await #expect(throws: MCPClientError.self) {
            try await client.callTool(name: "echo", arguments: [:])
        }
        #expect(
            Date().timeIntervalSince(started) < 5,
            "a dead connection must not make the request wait for its whole deadline"
        )
        await client.close()
    }

    // MARK: - The subprocess

    @Test("A real subprocess speaks the protocol")
    func aRealSubprocessSpeaksTheProtocol() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonk-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("server.sh")
        try Self.fakeServerScript.write(to: script, atomically: true, encoding: .utf8)

        let transport = MCPStdioTransport(configuration: MCPStdioTransport.Configuration(
            command: "/bin/sh",
            arguments: [script.path]
        ))
        let client = MCPClient(transport: transport, handshakeTimeout: 10, callTimeout: 10)
        let handshake = try await client.connect()
        #expect(handshake.protocolVersion == MCPProtocol.latestVersion)
        #expect(handshake.serverInfo.name == "fake")

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")

        let result = try await client.callTool(name: "echo", arguments: ["text": .string("hi")])
        #expect(result.textForModel.contains("echoed"))

        await client.close()
    }

    /// A server that speaks the protocol, in a shell script.
    ///
    /// It answers the three methods the client uses and nothing else.
    static let fakeServerScript = """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"id"'*) ;;
        *) continue ;;
      esac
      id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
      case "$line" in
        *'"initialize"'*)
          printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}\\n' "$id"
          ;;
        *'"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":"%s","result":{"tools":[{"name":"echo","description":"Echoes the text.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}}\\n' "$id"
          ;;
        *'"tools/call"'*)
          printf '{"jsonrpc":"2.0","id":"%s","result":{"content":[{"type":"text","text":"echoed"}]}}\\n' "$id"
          ;;
        *)
          printf '{"jsonrpc":"2.0","id":"%s","error":{"code":-32601,"message":"no such method"}}\\n' "$id"
          ;;
      esac
    done
    """

    /// Wait for a server to have heard a method.
    ///
    /// The notification the client sends after the handshake is answered
    /// by nothing, so the server hears it after the client is done.
    private func waitFor(
        _ method: String,
        on server: FakeMCPServer,
        seconds: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if server.methods.contains(method) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return server.methods.contains(method)
    }

    @Test("The waiter is in place before the request goes out")
    func theWaiterIsInPlaceBeforeTheRequest() throws {
        // An answer can come back the moment the request is on the wire.
        // A waiter registered afterwards never hears it, and the request
        // waits for a deadline it did not need. The order in the source
        // is the invariant; the timing that exposes it is a race.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Bonk/Services/Agent/MCP/MCPClient.swift"),
            encoding: .utf8
        )
        let register = try #require(source.range(of: "pending[identifier] = slot"))
        let send = try #require(source.range(of: "try await self.transport.send(wire)"))
        #expect(
            register.lowerBound < send.lowerBound,
            "the waiter has to be in place before the request goes out, or the answer is lost"
        )
    }

    @Test("The model is shown the servers' tools")
    @MainActor
    func theModelIsShownTheServersTools() async throws {
        // A server that speaks the protocol: the same shell script the
        // stdio test uses, in a temporary directory.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonk-mcp-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.sh")
        try Self.fakeServerScript.write(to: script, atomically: true, encoding: .utf8)

        let servers = MCPServerRegistry()
        // The server is a real child process: it goes away with the
        // registry, not with the end of the run.
        defer { servers.shutdown() }
        await servers.start(configurations: [
            MCPServerConfiguration(name: "fake", command: "/bin/sh", arguments: [script.path])
        ])
        #expect(servers.agentTools.count == 1, "the server's tool has to be collected")

        // The production path: the engine's tool loop, with a provider
        // that records the tool definitions it was handed. The model never
        // sees a tool that is not in that array.
        let capture = ToolCapturingProvider()
        let engine = AgentEngine()
        await engine.runAgentToolLoop(
            input: "hello",
            sshService: SSHNetworkService(hostKeyStore: NullHostKeyStore()),
            hybridSession: nil,
            hostName: nil,
            conversation: nil,
            context: nil,
            provider: capture,
            mcpServers: servers
        )

        #expect(
            capture.capturedTools.contains { $0.name == "mcp__fake__echo" },
            "the model's tool list has to hold the server's tool"
        )
    }

    // MARK: - The configuration

    @Test("The configuration names the servers to start")
    func theConfigurationNamesTheServers() throws {
        let root = try MCPJSONCoding.value(from: """
        {
          "mcpServers": {
            "github": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": { "GITHUB_TOKEN": "token" }
            }
          }
        }
        """)
        let servers = MCPServerConfigurationStore.configurations(from: root)
        #expect(servers.count == 1)
        #expect(servers.first?.name == "github")
        #expect(servers.first?.command == "npx")
        #expect(servers.first?.arguments == ["-y", "@modelcontextprotocol/server-github"])
        #expect(servers.first?.environment["GITHUB_TOKEN"] == "token")
    }

    @Test("A server with no command is skipped, the others are not")
    func aBrokenServerIsSkipped() throws {
        let root = try MCPJSONCoding.value(from: """
        {
          "mcpServers": {
            "broken": { "args": ["nothing"] },
            "bad name": { "command": "true" },
            "fine": { "command": "true" }
          }
        }
        """)
        let servers = MCPServerConfigurationStore.configurations(from: root)
        #expect(servers.count == 1)
        #expect(servers.first?.name == "fine")
    }

    @Test("A missing configuration file is not an error")
    func aMissingConfigurationIsNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonk-no-such-mcp-\(UUID().uuidString).json")
        #expect(MCPServerConfigurationStore.load(from: missing).isEmpty)
    }

    // MARK: - The wiring

    @Test("The agent path starts the servers and registers their tools")
    func theAgentPathWiresTheServers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executor = try String(
            contentsOf: root.appendingPathComponent("Bonk/Services/Agent/AgentToolExecutor.swift"),
            encoding: .utf8
        )
        #expect(executor.contains("await mcpServers.start()"),
                "the agent path must start the configured MCP servers")
        #expect(executor.contains("toolRegistry.register(tool)"),
                "the agent path must put the servers' tools in front of the model")
    }
}

/// A server that answers the protocol, over the in-memory transport.
///
/// It is the counterpart of the client in the tests: it answers the
/// handshake, lists the tools it was given, and calls back with the
/// answer it was given.
final class FakeMCPServer: @unchecked Sendable {
    /// The methods the server was asked for.
    private let recorded = MethodRecorder()

    var methods: Set<String> { recorded.methods }

    /// What the server offers.
    var tools: [MCPJSONValue] = []
    /// What a tool call answers.
    var callResult: MCPJSONValue = .object(["content": .array([])])
    /// The error a tool call fails with, when it is meant to fail.
    var error: MCPJSONRPCError?
    /// The protocol version the server answers the handshake with.
    var protocolVersion: String = MCPProtocol.latestVersion

    /// Answer the client on the other side of the transport.
    @discardableResult
    static func answering(
        transport: MCPInMemoryTransport,
        tools: [MCPJSONValue],
        callResult: MCPJSONValue = .object(["content": .array([])]),
        error: MCPJSONRPCError? = nil,
        protocolVersion: String = MCPProtocol.latestVersion
    ) -> FakeMCPServer {
        let server = FakeMCPServer()
        server.tools = tools
        server.callResult = callResult
        server.error = error
        server.protocolVersion = protocolVersion
        Task {
            for await event in transport.events {
                guard case let .message(message) = event else { continue }
                switch message {
                case let .request(id, method, _):
                    server.recorded.add(method)
                    await server.answer(transport: transport, id: id, method: method)
                case let .notification(method, _):
                    server.recorded.add(method)
                case .response, .failure:
                    continue
                }
            }
        }
        return server
    }

    /// Answer one request.
    private func answer(transport: MCPInMemoryTransport, id: String, method: String) async {
        do {
            switch method {
            case MCPMethod.initialize:
                try await transport.send(MCPJSONCoding.response(
                    id: id,
                    result: .object([
                        "protocolVersion": .string(protocolVersion),
                        "capabilities": .object([:]),
                        "serverInfo": .object([
                            "name": .string("fake"),
                            "version": .string("1")
                        ])
                    ])
                ))
            case MCPMethod.toolsList:
                try await transport.send(MCPJSONCoding.response(
                    id: id,
                    result: .object(["tools": .array(tools)])
                ))
            case MCPMethod.toolsCall:
                if let error {
                    try await transport.send(MCPJSONCoding.failure(id: id, error: error))
                } else {
                    try await transport.send(MCPJSONCoding.response(id: id, result: callResult))
                }
            default:
                try await transport.send(MCPJSONCoding.failure(
                    id: id,
                    error: MCPJSONRPCError(code: -32601, message: "no such method")
                ))
            }
        } catch {
            return
        }
    }

    /// The methods a server was asked for.
    final class MethodRecorder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Set<String>>(uncheckedState: [])
        var methods: Set<String> { lock.withLock { $0 } }
        func add(_ method: String) { lock.withLock { $0.insert(method) } }
    }
}


/// A transport whose peer died without closing its end.
///
/// The write side is still open, so a request goes out and nothing
/// answers it: the request is lost silently. That is the case the
/// client's fast-fail is for — without it the request waits for its
/// whole deadline, and the agent's turn hangs on a server that is
/// already gone.
final class SwallowingTransport: MCPTransport, @unchecked Sendable {
    private let inner: MCPInMemoryTransport
    private let dead = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

    init(inner: MCPInMemoryTransport) {
        self.inner = inner
    }

    /// The peer is gone, and the pipe still takes writes.
    func peerDied() {
        dead.withLock { $0 = true }
    }

    func start() async throws { try await inner.start() }
    func close() async { await inner.close() }
    var events: AsyncStream<MCPTransportEvent> { inner.events }

    func send(_ message: MCPJSONValue) async throws {
        if dead.withLock({ $0 }) {
            // The write succeeds. Nobody is there to answer it.
            return
        }
        try await inner.send(message)
    }
}

// MARK: - The production path

/// A provider that records the tool definitions it was handed.
///
/// The tool definitions are what the model is shown, so they are the
/// boundary: a server's tool that never reaches this array is a tool
/// the model cannot call.
final class ToolCapturingProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LLMToolDefinition] = []

    /// Exactly the tool definitions the provider was handed.
    var capturedTools: [LLMToolDefinition] {
        lock.withLock { stored }
    }

    let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000000C50")!
    let providerName = "capturing"
    let capability = ModelCapability()

    func chat(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) async throws -> LLMResponse {
        LLMResponse(text: "captured")
    }

    func stream(
        messages: [LLMMessage],
        maxTokens: Int?,
        disableReasoning: Bool
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func toolCall(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int?
    ) async throws -> LLMResponse {
        let captured = tools
        lock.withLock { stored = captured }
        return LLMResponse(text: "captured")
    }

    func listModels() async throws -> [String] { ["capturing"] }
    func testConnection() async throws -> Bool { true }
}
