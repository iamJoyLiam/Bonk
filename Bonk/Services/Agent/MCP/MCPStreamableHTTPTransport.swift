//
//  MCPStreamableHTTPTransport.swift
//  Bonk
//
//  An MCP server reached over Streamable HTTP.
//
//  The client posts JSON-RPC messages to the server's endpoint and reads
//  answers back over the same HTTP connection (or on a Server-Sent Events
//  stream). The transport is transport-agnostic from the client core's
//  point of view: it hands messages to the transport and reads what comes
//  back, exactly like the stdio transport.
//
//  Three things worth stating:
//
//  **Every request is bounded.** A server that accepts a call and never
//  answers must not hold the agent's turn open, so each request carries a
//  deadline and the pending call fails when it passes. That deadline is
//  enforced by MCPClient on top of this transport; the transport itself
//  only has to deliver and report when the connection is gone.
//
//  **The connection is per-server.** One transport talks to one server.
//  The user's config names the server and its endpoint; this transport is
//  built for that one endpoint.
//
//  **The server can push messages at any time.** A server-initiated
//  notification (for example a progress token or a sampling request) can
//  arrive while the client is waiting for an answer to something else. The
//  event stream delivers those as they come, so they are never confused
//  with an answer to a pending call.
//

import Foundation
import os

/// The configuration of one Streamable HTTP MCP server.
extension MCPStreamableHTTPTransport {
    struct Configuration: Sendable {
        /// The endpoint the client posts JSON-RPC messages to.
        let endpointURL: URL
        /// Extra HTTP headers sent with every request.
        let headers: [String: String]
        /// How long a single request/response round-trip may take.
        let timeout: TimeInterval

        init(
            endpointURL: URL,
            headers: [String: String] = [:],
            timeout: TimeInterval = 30
        ) {
            self.endpointURL = endpointURL
            self.headers = headers
            self.timeout = timeout
        }
    }
}

/// One MCP server reached over Streamable HTTP.
///
/// The transport opens one HTTP connection to the server and keeps it
/// open as an event stream for server-initiated messages. Every request
/// the client sends is an HTTP POST to the same endpoint; the answer
/// comes back either in that response's body or on the event stream.
final class MCPStreamableHTTPTransport: MCPTransport, @unchecked Sendable {
    /// The largest message this transport will read or send.
    static let maxMessageBytes = 16 * 1024 * 1024

    private static let logger = Logger(subsystem: "com.bonk", category: "MCP")

    private let configuration: Configuration
    private let session = URLSession(configuration: .default)

    /// The parts more than one thread touches.
    private struct State {
        var closed = false
        var eventTask: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    private let (eventStream, continuation) = AsyncStream<MCPTransportEvent>.makeStream()

    var events: AsyncStream<MCPTransportEvent> { eventStream }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Open the event stream the server pushes server-initiated messages
        // onto. A server that does not support streaming answers every
        // request in the response body instead; this stream simply stays
        // silent until the server has something to say.
        try await openEventStream()
    }

    func send(_ message: MCPJSONValue) async throws {
        let isClosed = state.withLock { $0.closed }
        guard !isClosed else { throw MCPTransportClosedError() }

        let payload = try MCPJSONCoding.data(from: message)
        guard payload.count <= Self.maxMessageBytes else {
            throw MCPTransportError.messageTooLarge
        }

        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPTransportError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw MCPTransportError.serverError(
                    code: httpResponse.statusCode,
                    message: String(data: data, encoding: .utf8) ?? ""
                )
            }
            guard !data.isEmpty else {
                // The server accepted the request but answered on the event
                // stream instead. Nothing to hand up yet.
                return
            }
            let message = try MCPJSONCoding.value(from: data)
            let rpcMessage = try MCPJSONCoding.message(from: message)
            continuation.yield(.message(rpcMessage))
        } catch let error as MCPTransportError {
            throw error
        } catch {
            throw MCPTransportError.connectionClosed(reason: error.localizedDescription)
        }
    }

    func close() async {
        end(with: nil)
    }

    // MARK: - Private

    private func openEventStream() async throws {
        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("text/event-stream", forHTTPHeaderField: "Content-Type")
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPTransportError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MCPTransportError.serverError(
                code: httpResponse.statusCode,
                message: ""
            )
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in bytes.lines {
                    guard !state.withLock({ $0.closed }) else { break }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.hasPrefix("data: ")
                    else { continue }
                    let jsonString = String(trimmed.dropFirst("data: ".count))
                    guard let data = jsonString.data(using: .utf8) else { continue }
                    do {
                        let message = try MCPJSONCoding.value(from: data)
                        let rpcMessage = try MCPJSONCoding.message(from: message)
                        self.continuation.yield(.message(rpcMessage))
                    } catch {
                        Self.logger.debug("Ignoring an unreadable MCP event: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                guard !state.withLock({ $0.closed }) else { return }
                self.end(with: error)
            }
        }

        state.withLock { $0.eventTask = task }
    }

    private func end(with error: Error?) {
        let wasClosed = state.withLock { state -> Bool in
            guard !state.closed else { return true }
            state.closed = true
            return false
        }
        guard !wasClosed else { return }

        state.withLock { $0.eventTask?.cancel() }

        continuation.yield(.ended(error))
        continuation.finish()
    }
}

// MARK: - Errors

enum MCPTransportError: Error, Equatable {
    case invalidResponse
    case serverError(code: Int, message: String)
    case connectionClosed(reason: String?)
    case messageTooLarge

    static func == (lhs: MCPTransportError, rhs: MCPTransportError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse): return true
        case let (.serverError(lCode, lMessage), .serverError(rCode, rMessage)):
            return lCode == rCode && lMessage == rMessage
        case let (.connectionClosed(lReason), .connectionClosed(rReason)):
            return lReason == rReason
        case (.messageTooLarge, .messageTooLarge): return true
        default: return false
        }
    }
}
