//
//  MCPClient.swift
//  Bonk
//
//  The client half of the Model Context Protocol.
//
//  Three requests are all the agent needs: the handshake, the list of a
//  server's tools, and the call of one of them.
//
//  **Every request is bounded.** A server that accepts a call and never
//  answers must not hold the agent's turn open forever, so each request
//  carries a deadline and the pending call fails when it passes.
//
//  **The handshake is checked.** A server that answers with a protocol
//  version this client does not implement is refused: the shapes below
//  are version-specific, and talking to a server that speaks a different
//  dialect is how a client ends up parsing a response that means
//  something else.
//
//  **A dead connection fails every pending call.** When the transport
//  ends, whatever was waiting on it fails too, rather than waiting for a
//  deadline that may be minutes away.
//

import Foundation
import os

/// A failure talking to an MCP server.
enum MCPClientError: Error, Equatable, Sendable {
    /// The server did not answer in time.
    case timedOut(method: String, seconds: TimeInterval)
    /// The server answered with an error.
    case serverError(code: Int, message: String)
    /// The server answered with something this client cannot use.
    case malformedResponse(method: String, reason: String)
    /// The server speaks a protocol version this client does not know.
    case unsupportedProtocolVersion(String)
    /// The connection is gone.
    case connectionClosed(reason: String?)
}

/// One call's slot.
///
/// The answer and the deadline both finish the same call, so whichever
/// arrives first wins and the other is ignored. Resuming a continuation
/// twice is a crash, and this is where that is prevented.
final class MCPCallSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<MCPJSONRPCMessage, Error>

    init(_ continuation: CheckedContinuation<MCPJSONRPCMessage, Error>) {
        self.continuation = continuation
    }

    /// Finish the call. The second attempt does nothing.
    func resume(with result: Result<MCPJSONRPCMessage, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        switch result {
        case let .success(message):
            continuation.resume(returning: message)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

/// Talks to one MCP server.
actor MCPClient {
    /// How long the handshake may take.
    static let handshakeTimeout: TimeInterval = 15

    /// How long a tool call may take.
    ///
    /// A tool that talks to a database is allowed to be slow; a tool that
    /// never answers is not allowed to hold the turn.
    static let callTimeout: TimeInterval = 60

    private static let logger = Logger(subsystem: "com.bonk", category: "MCP")

    private let transport: any MCPTransport
    private let handshakeTimeout: TimeInterval
    private let callTimeout: TimeInterval
    /// The calls waiting for an answer, by request id.
    ///
    /// This is the table the **answer** is looked up in. The deadline
    /// does not use it — it holds the call's slot itself — so a call
    /// whose answer was lost still ends at its deadline.
    private var pending: [String: MCPCallSlot] = [:]
    /// The deadline timer of each call in flight.
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var nextIdentifier = 1
    private var readerTask: Task<Void, Never>?
    private var protocolVersion: String?
    private var serverInfo: MCPServerInfo?
    private var closed = false
    /// Why the connection is gone, once it is.
    ///
    /// A request that is made after the connection died has no answer to
    /// wait for. Without this, such a request waits for its whole
    /// deadline — the agent's turn hangs on a server that is already
    /// gone.
    private var connectionError: Error?

    init(
        transport: any MCPTransport,
        handshakeTimeout: TimeInterval = MCPClient.handshakeTimeout,
        callTimeout: TimeInterval = MCPClient.callTimeout
    ) {
        self.transport = transport
        self.handshakeTimeout = handshakeTimeout
        self.callTimeout = callTimeout
    }

    /// What the server calls itself.
    var connectedServerInfo: MCPServerInfo? { serverInfo }

    /// The protocol version the handshake settled on.
    var negotiatedProtocolVersion: String? { protocolVersion }

    /// Whether the connection is gone.
    ///
    /// A request made after this is true fails at once instead of
    /// waiting for its deadline: there is nobody left to answer it.
    var connectionIsDead: Bool { connectionError != nil }

    // MARK: - The handshake

    /// Start the transport and shake hands.
    func connect() async throws -> MCPInitializeResult {
        connectionError = nil
        try await transport.start()
        startReading()

        let params = MCPJSONValue.object([
            "protocolVersion": .string(MCPProtocol.latestVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Bonk"),
                "version": .string(Bundle.main.appVersion)
            ])
        ])

        let result = try await request(
            method: MCPMethod.initialize,
            params: params,
            timeout: handshakeTimeout
        )
        guard let object = result.objectValue else {
            throw MCPClientError.malformedResponse(
                method: MCPMethod.initialize,
                reason: "the answer is not an object"
            )
        }
        let version = object["protocolVersion"]?.stringValue ?? ""
        guard MCPProtocol.isSupported(version) else {
            throw MCPClientError.unsupportedProtocolVersion(version)
        }
        let info = object["serverInfo"]?.objectValue
        protocolVersion = version
        serverInfo = MCPServerInfo(
            name: info?["name"]?.stringValue ?? "unknown",
            version: info?["version"]?.stringValue ?? "unknown"
        )
        // The server expects this before it will answer anything else.
        try await transport.send(
            MCPJSONCoding.notification(method: MCPMethod.initialized, params: nil)
        )
        return MCPInitializeResult(
            protocolVersion: version,
            serverInfo: serverInfo ?? MCPServerInfo(name: "unknown", version: "unknown"),
            instructions: object["instructions"]?.stringValue
        )
    }

    // MARK: - Tools

    /// Every tool the server offers.
    func listTools() async throws -> [MCPToolDescriptor] {
        var tools: [MCPToolDescriptor] = []
        var cursor: String?
        // A server may page its tools; the cursor is followed until it
        // stops handing one out.
        for _ in 0..<Self.maxToolPages {
            var params: MCPJSONValue?
            if let cursor {
                params = .object(["cursor": .string(cursor)])
            }
            let result = try await request(
                method: MCPMethod.toolsList,
                params: params,
                timeout: handshakeTimeout
            )
            guard let object = result.objectValue,
                  let list = object["tools"]?.arrayValue
            else {
                throw MCPClientError.malformedResponse(
                    method: MCPMethod.toolsList,
                    reason: "the answer has no tool list"
                )
            }
            tools.append(contentsOf: list.compactMap(Self.tool(from:)))
            cursor = object["nextCursor"]?.stringValue
            guard let cursor, !cursor.isEmpty else { break }
        }
        return tools
    }

    /// Call one of the server's tools.
    func callTool(name: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolCallResult {
        let params = MCPJSONValue.object([
            "name": .string(name),
            "arguments": .object(arguments)
        ])
        let result = try await request(
            method: MCPMethod.toolsCall,
            params: params,
            timeout: callTimeout
        )
        guard let object = result.objectValue else {
            throw MCPClientError.malformedResponse(
                method: MCPMethod.toolsCall,
                reason: "the answer is not an object"
            )
        }
        let blocks = (object["content"]?.arrayValue ?? []).compactMap(Self.content(from:))
        return MCPToolCallResult(
            content: blocks,
            isError: object["isError"]?.boolValue ?? false
        )
    }

    /// Close the connection.
    func close() async {
        guard !closed else { return }
        closed = true
        connectionError = MCPClientError.connectionClosed(reason: "the client was closed")
        readerTask?.cancel()
        readerTask = nil
        failPending(with: connectionError ?? MCPClientError.connectionClosed(reason: "the client was closed"))
        await transport.close()
    }

    // MARK: - The wire

    private func request(
        method: String,
        params: MCPJSONValue?,
        timeout: TimeInterval
    ) async throws -> MCPJSONValue {
        let identifier = String(nextIdentifier)
        nextIdentifier += 1
        let wire = MCPJSONCoding.request(id: identifier, method: method, params: params)

        defer { cancelDeadline(identifier: identifier) }
        let message = try await sendAndWait(
            identifier: identifier,
            wire: wire,
            method: method,
            timeout: timeout
        )
        switch message {
        case let .response(_, result):
            return result
        case let .failure(_, error):
            throw MCPClientError.serverError(code: error.code, message: error.message)
        case .request, .notification:
            throw MCPClientError.malformedResponse(
                method: "unknown",
                reason: "the server sent a request where an answer was expected"
            )
        }
    }

    /// Put the request on the wire and wait for its answer.
    ///
    /// The waiter is registered **before** the request goes out. An
    /// answer can come back the moment the request is on the wire, and
    /// a waiter registered afterwards never hears it — which is not a
    /// slow server, it is a lost answer and a request that waits for a
    /// deadline it did not need.
    private func sendAndWait(
        identifier: String,
        wire: MCPJSONValue,
        method: String,
        timeout: TimeInterval
    ) async throws -> MCPJSONRPCMessage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPJSONRPCMessage, Error>) in
                // The cancellation may arrive before this continuation is
                // registered — the handler runs on another thread and the
                // body runs here. Checking before the wait is what keeps
                // a cancelled request from waiting for an answer that
                // will never arrive.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let slot = MCPCallSlot(continuation)
                // The deadline is armed first, and it holds the slot
                // itself. A call whose answer was lost — the answer came
                // back before the waiter was in place — must still end at
                // its deadline instead of holding the agent's turn open.
                armDeadline(identifier: identifier, slot: slot, method: method, timeout: timeout)
                pending[identifier] = slot
                // The connection may have died between the request being
                // made and this waiter being in place. Both this check
                // and the failure of the pending waiters happen on the
                // actor, so one of the two sees it.
                if let connectionError {
                    abandon(identifier: identifier, error: connectionError)
                    return
                }
                // The request goes out only now, with the waiter already
                // in place.
                Task {
                    do {
                        try await self.transport.send(wire)
                    } catch {
                        self.abandon(
                            identifier: identifier,
                            error: MCPClientError.connectionClosed(reason: error.localizedDescription)
                        )
                    }
                }
            }
        } onCancel: {
            Task { await self.abandon(identifier: identifier) }
        }
    }

    /// Arm the deadline of one call.
    ///
    /// The timer holds the call's slot rather than looking it up, so the
    /// deadline does not depend on the answer's table. A call whose
    /// answer is lost still fails at its deadline instead of waiting for
    /// a second one.
    private func armDeadline(
        identifier: String,
        slot: MCPCallSlot,
        method: String,
        timeout: TimeInterval
    ) {
        deadlines[identifier] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            slot.resume(with: .failure(MCPClientError.timedOut(method: method, seconds: timeout)))
            await self.dropCall(identifier: identifier)
        }
    }

    /// Stop a deadline that is no longer needed.
    private func cancelDeadline(identifier: String) {
        deadlines[identifier]?.cancel()
        deadlines[identifier] = nil
    }

    /// Forget a call that is over.
    private func dropCall(identifier: String) {
        pending[identifier] = nil
    }

    /// Drop a request that will never be answered.
    private func abandon(identifier: String, error: Error = CancellationError()) {
        guard let slot = pending.removeValue(forKey: identifier) else { return }
        slot.resume(with: .failure(error))
    }

    /// Fail everything that was waiting on a connection that is gone.
    private func failPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for slot in waiting.values {
            slot.resume(with: .failure(error))
        }
    }

    /// Read the transport for the life of the connection.
    private func startReading() {
        readerTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.events {
                await self.handle(event)
            }
            await self.failPending(with: MCPTransportClosedError(reason: "the transport ended"))
        }
    }

    private func handle(_ event: MCPTransportEvent) {
        switch event {
        case let .message(message):
            guard let identifier = message.responseId else {
                // A notification. This client asks the server for nothing
                // it cannot answer, so there is nothing to do with one.
                return
            }
            guard let slot = pending.removeValue(forKey: identifier) else { return }
            slot.resume(with: .success(message))
        case let .ended(error):
            // The connection is gone. Every request made from now on has
            // no answer to wait for.
            // A transport failure is a client failure: the caller asks
            // the client what went wrong, not the pipe.
            let reason = MCPClientError.connectionClosed(reason: error?.localizedDescription)
            connectionError = reason
            failPending(with: reason)
        }
    }

    // MARK: - Reading the answers

    /// How many pages of tools a server may hand out.
    static let maxToolPages = 50

    /// One tool, from the server's answer.
    static func tool(from value: MCPJSONValue) -> MCPToolDescriptor? {
        guard let object = value.objectValue,
              let name = object["name"]?.stringValue,
              !name.isEmpty
        else { return nil }
        return MCPToolDescriptor(
            name: name,
            title: object["title"]?.stringValue,
            description: object["description"]?.stringValue,
            inputSchema: object["inputSchema"],
            annotations: object["annotations"]
        )
    }

    /// One content block, from the server's answer.
    static func content(from value: MCPJSONValue) -> MCPContentBlock? {
        guard let object = value.objectValue,
              let kind = object["type"]?.stringValue
        else { return nil }
        if kind == "text" {
            return .text(object["text"]?.stringValue ?? "")
        }
        return .other(kind: kind)
    }
}

extension Bundle {
    /// The app's version, for the handshake.
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
}
