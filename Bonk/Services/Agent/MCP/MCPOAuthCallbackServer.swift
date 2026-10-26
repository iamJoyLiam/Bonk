//
//  MCPOAuthCallbackServer.swift
//  Bonk
//
//  A tiny HTTP server that listens on localhost for the OAuth redirect.
//
//  When the user authorizes Bonk on an MCP server's authorization page,
//  the provider redirects the browser to a localhost URL with the
//  authorization code. This server captures that code and hands it back
//  to the MCPAuthenticationManager.
//
//  The server listens on a randomly chosen port and shuts itself down
//  after the first successful callback or after a timeout.
//

import Foundation
import os
import Network

/// An error from the OAuth callback server.
enum MCPOAuthCallbackError: Error {
    case serverStartFailed(Error)
    case noRedirectReceived
    case redirectTimedOut
}

/// The result of an OAuth redirect: either an authorization code or an error.
enum OAuthRedirectResult: Error {
    case authorizationCode(String)
    case error(String)
}

/// A tiny HTTP server that captures the OAuth redirect.
final class MCPOAuthCallbackServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.bonk", category: "MCP")

    private let listener: NWListener
    private var continuation: CheckedContinuation<OAuthRedirectResult, Error>?
    private var isRunning = false

    init(port: UInt16) throws {
        do {
            // Port 0 (ephemeral) is the only supported value; the OS assigns
            // a free port when the listener starts.
            guard port == 0 else {
                throw MCPOAuthCallbackError.serverStartFailed(NSError(domain: "com.bonk.mcp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Only ephemeral port (0) is supported, got \(port)"]))
            }
            self.listener = try NWListener(using: .tcp)
        } catch {
            throw MCPOAuthCallbackError.serverStartFailed(error)
        }
        self.continuation = nil
    }

    /// Start listening and wait for one redirect.
    ///
    /// Returns when the redirect arrives, or after `timeout` seconds.
    func waitForRedirect(timeout: TimeInterval = 300) async throws -> OAuthRedirectResult {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: MCPOAuthCallbackError.serverStartFailed(NSError(domain: "com.bonk.mcp", code: -1)))
                return
            }
            self.continuation = continuation

            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state else { return }
                self.startListening()
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            self.listener.start(queue: .global())
            self.isRunning = true

            // Timeout watchdog
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                if self.isRunning {
                    self.stop()
                    self.continuation?.resume(throwing: MCPOAuthCallbackError.redirectTimedOut)
                }
            }
        }
    }

    private func startListening() {
        // Listening is already started via listener.start(queue:) above.
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
                    guard let self, let connection else { return }
                    if let data, !data.isEmpty {
                        self.handleHTTPRequest(data: data, connection: connection)
                    }
                    connection.cancel()
                }
            }
            connection.start(queue: .global())
        }
    }

    private func handleHTTPRequest(data: Data, connection: NWConnection) {
        guard let text = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        // Parse the first line: "GET /callback?code=XXX&state=YYY HTTP/1.1"
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendResponse(connection: connection, status: 400, body: "Bad Request")
            connection.cancel()
            return
        }

        let path = parts[1]
        guard let url = URL(string: "http://localhost\(path)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            sendResponse(connection: connection, status: 400, body: "Missing authorization code")
            connection.cancel()
            return
        }

        // Check for error from the provider
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            sendResponse(connection: connection, status: 400, body: "Authorization error: \(error)")
            connection.cancel()
            continuation?.resume(throwing: MCPOAuthCallbackError.redirectTimedOut)
            return
        }

        // Success - send a nice page to the user
        let html = """
        <html>
        <head><title>Bonk - Authorization Complete</title></head>
        <body>
        <h1>Authorization Complete</h1>
        <p>You have successfully authorized Bonk. You can close this window.</p>
        <script>window.close();</script>
        </body>
        </html>
        """
        sendResponse(connection: connection, status: 200, body: html)
        connection.cancel()
        continuation?.resume(returning: OAuthRedirectResult.authorizationCode(code))
    }

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusLine = "HTTP/1.1 \(status) \(statusText(for: status))\r\n"
        let headers = """
        \(statusLine)
        Content-Type: text/html; charset=utf-8
        Content-Length: \(body.utf8.count)
        Connection: close

        """
        let response = headers + body
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in }))
    }

    private func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        default: return "Unknown"
        }
    }

    func stop() {
        isRunning = false
        listener.cancel()
    }
}
