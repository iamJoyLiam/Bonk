//
//  MCPTransport.swift
//  Bonk
//
//  How MCP messages travel.
//
//  The client core knows nothing about pipes, sockets or processes: it
//  hands a message to a transport and reads what comes back. That split
//  is what makes the client testable — a test drives the real client
//  core over an in-memory pipe, with no subprocess and no port.
//
//  The transport reports two things: the messages the peer sends, and
//  the fact that it ended. A client with a request in flight needs to
//  know which happened first, or it waits forever.
//

import Foundation
import os

/// Something that happened on a transport.
enum MCPTransportEvent: Sendable {
    /// A message from the peer.
    case message(MCPJSONRPCMessage)
    /// The transport ended. The error is nil when it ended cleanly.
    case ended(Error?)
}

/// A connection to an MCP server.
protocol MCPTransport: AnyObject, Sendable {
    /// Open the connection.
    func start() async throws

    /// Send one message.
    func send(_ message: MCPJSONValue) async throws

    /// Close the connection. Calling it twice is harmless.
    func close() async

    /// What the peer does.
    var events: AsyncStream<MCPTransportEvent> { get }
}

/// The transport is gone.
struct MCPTransportClosedError: Error, Equatable {
    let reason: String?

    init(reason: String? = nil) {
        self.reason = reason
    }
}

// MARK: - In memory

/// Two transports wired to each other.
///
/// The test transport: no subprocess, no socket, no port. One side's
/// `send` shows up on the other side's event stream.
final class MCPInMemoryTransport: MCPTransport, @unchecked Sendable {
    private struct State {
        var peer: MCPInMemoryTransport?
        var started = false
        var closed = false
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    // The stream is made once, so a message sent before the reader starts
    // iterating is buffered by the stream rather than lost.
    private let (eventStream, continuation) = AsyncStream<MCPTransportEvent>.makeStream()

    init() {}

    /// A pair of transports, each one delivering to the other.
    static func connect() -> (client: MCPInMemoryTransport, server: MCPInMemoryTransport) {
        let client = MCPInMemoryTransport()
        let server = MCPInMemoryTransport()
        client.state.withLock { $0.peer = server }
        server.state.withLock { $0.peer = client }
        return (client, server)
    }

    var events: AsyncStream<MCPTransportEvent> { eventStream }

    func start() async throws {
        state.withLock { state in
            guard !state.started else { return }
            state.started = true
        }
    }

    func send(_ message: MCPJSONValue) async throws {
        let encoded = try MCPJSONCoding.data(from: message)
        let decoded = try MCPJSONCoding.message(from: encoded)
        let (target, isClosed) = state.withLock { state in
            (state.peer, state.closed)
        }
        guard !isClosed else {
            throw MCPTransportClosedError()
        }
        target?.deliver(.message(decoded))
    }

    func close() async {
        let wasClosed = state.withLock { state -> Bool in
            guard !state.closed else { return true }
            state.closed = true
            return false
        }
        guard !wasClosed else { return }
        continuation.yield(.ended(nil))
        continuation.finish()
    }

    /// Deliver an event to this side's listener.
    func deliver(_ event: MCPTransportEvent) {
        continuation.yield(event)
    }

    /// Close this side and tell the peer.
    func terminate(with error: Error?) {
        let wasClosed = state.withLock { state -> Bool in
            guard !state.closed else { return true }
            state.closed = true
            return false
        }
        guard !wasClosed else { return }
        continuation.yield(.ended(error))
        continuation.finish()
        state.withLock { $0.peer }?.deliver(.ended(error))
    }
}
