//
//  MCPStdioTransport.swift
//  Bonk
//
//  An MCP server reached over a subprocess pipe.
//
//  The server is a local program the user configured; this transport
//  starts it, writes JSON-RPC messages to its stdin, and reads them back
//  from its stdout, one message per line.
//
//  Three things here are not obvious:
//
//  **The framing is a line, not a packet.** A message can arrive in
//  pieces, and several messages can arrive in one read. The buffer is
//  only cut at newlines.
//
//  **A server that never answers must not wedge the agent.** Every
//  message is bounded, and the client times out on top of that.
//
//  **The process has to die with the app.** Closing stdin is the polite
//  way; a server that ignores it gets SIGTERM, then SIGKILL. The child
//  is put in its own process group when the platform allows it, so a
//  wrapper such as `npx` does not leave the real server running.
//

import Foundation
import os

/// An MCP server run as a local subprocess.
final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    /// How the server is started.
    struct Configuration: Sendable {
        let command: String
        let arguments: [String]
        /// Extra environment entries. The server also inherits the app's.
        let environment: [String: String]
        let workingDirectory: String?
        /// OAuth bearer token, if the server requires OAuth.
        /// Passed as `BONK_MCP_BEARER_TOKEN` in the environment.
        let bearerToken: String?

        init(
            command: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            workingDirectory: String? = nil,
            bearerToken: String? = nil
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.bearerToken = bearerToken
        }
    }

    /// The largest message this transport will read.
    ///
    /// A server that sends a gigabyte of JSON is not a server this client
    /// can talk to, and the buffer has to stop somewhere.
    static let maxMessageBytes = 16 * 1024 * 1024

    /// How much of the server's stderr is kept for diagnostics.
    static let maxStderrBytes = 64 * 1024

    /// How long the server gets to exit on its own after stdin closes.
    static let closeGraceSeconds: TimeInterval = 0.5

    private static let logger = Logger(subsystem: "com.bonk", category: "MCP")

    private let configuration: Configuration
    private let process = Process()

    /// The parts of the transport that more than one thread touches.
    private struct State {
        var buffer = Data()
        var stderrBuffer = Data()
        var closed = false
        var inOwnProcessGroup = false
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    private let (eventStream, continuation) = AsyncStream<MCPTransportEvent>.makeStream()

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    var events: AsyncStream<MCPTransportEvent> { eventStream }

    // MARK: - Lifecycle

    func start() async throws {
        let executable = URL(fileURLWithPath: configuration.command)
        process.executableURL = executable
        process.arguments = configuration.arguments
        if !configuration.environment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in configuration.environment {
                environment[key] = value
            }
            process.environment = environment
        }
        if let workingDirectory = configuration.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        // Build the environment: start with the process environment,
        // overlay the configured environment, then add the bearer token
        // if one was provided. The bearer token is passed as
        // BONK_MCP_BEARER_TOKEN so the server can read it.
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in configuration.environment {
            processEnvironment[key] = value
        }
        if let bearerToken = configuration.bearerToken {
            processEnvironment["BONK_MCP_BEARER_TOKEN"] = bearerToken
        }
        process.environment = processEnvironment

        do {
            try process.run()
        } catch {
            throw MCPTransportLaunchError.couldNotStart(
                command: configuration.command,
                reason: error.localizedDescription
            )
        }

        // Best effort: a child in its own group can be signalled as a
        // group, so a wrapper that spawns the real server does not leave
        // it behind. If the child has already exec'd this fails, and the
        // direct child is signalled instead.
        let inOwnGroup = setpgid(process.processIdentifier, process.processIdentifier) == 0
        state.withLock { $0.inOwnProcessGroup = inOwnGroup }

        readOutput(from: output.fileHandleForReading)
        readErrors(from: error.fileHandleForReading)

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let status = process.terminationStatus
            let reason = status == 0
                ? nil
                : "MCP server exited with status \(status)"
            self.end(with: reason.map { MCPTransportClosedError(reason: $0) })
        }
    }

    func close() async {
        end(with: nil)
    }

    /// Stop the server without waiting for anything.
    ///
    /// The app is quitting: there is no time to await an actor, and a
    /// server left running after the app is gone is a server nobody is
    /// left to talk to.
    func terminateNow() {
        end(with: nil)
    }

    // MARK: - Sending

    func send(_ message: MCPJSONValue) async throws {
        let isClosed = state.withLock { $0.closed }
        guard !isClosed else { throw MCPTransportClosedError() }

        var payload = try MCPJSONCoding.data(from: message)
        payload.append(0x0A) // one message per line
        guard let input = process.standardInput as? Pipe else {
            throw MCPTransportClosedError(reason: "the server has no input pipe")
        }
        try await input.fileHandleForWriting.write(contentsOf: payload)
    }

    // MARK: - Reading

    private func readOutput(from handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                // The pipe closed: the server is gone or said its last word.
                self.end(with: nil)
                return
            }
            self.consumeOutput(data)
        }
    }

    private func consumeOutput(_ data: Data) {
        let (lines, overflow) = state.withLock { state -> ([Data], Bool) in
            var lines: [Data] = []
            state.buffer.append(data)
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                let line = state.buffer[state.buffer.startIndex..<newline]
                state.buffer = state.buffer[state.buffer.index(after: newline)...]
                lines.append(Data(line))
            }
            // A message that never ends is a message this client will not read.
            var overflow = false
            if state.buffer.count > Self.maxMessageBytes {
                state.buffer = Data()
                overflow = true
            }
            return (lines, overflow)
        }

        for line in lines {
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maxMessageBytes else { continue }
            let text = String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let text, !text.isEmpty else { continue }
            do {
                let message = try MCPJSONCoding.message(from: text)
                continuation.yield(.message(message))
            } catch {
                // A line that is not a message is the server's problem,
                // not a reason to drop the connection.
                Self.logger.debug("Ignoring an unreadable MCP message: \(error.localizedDescription, privacy: .public)")
            }
        }
        if overflow {
            Self.logger.error("An MCP message exceeded \(Self.maxMessageBytes, privacy: .public) bytes and was dropped")
        }
    }

    private func readErrors(from handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.state.withLock { state in
                state.stderrBuffer.append(data)
                if state.stderrBuffer.count > Self.maxStderrBytes {
                    state.stderrBuffer = Data(state.stderrBuffer.suffix(Self.maxStderrBytes))
                }
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            Self.logger.debug("MCP server stderr: \(text, privacy: .public)")
        }
    }

    // MARK: - Ending

    private func end(with error: Error?) {
        let wasClosed = state.withLock { state -> Bool in
            guard !state.closed else { return true }
            state.closed = true
            return false
        }
        guard !wasClosed else { return }

        // Ask the server to stop, then insist.
        (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        if process.isRunning {
            signal(SIGTERM)
            let deadline = Date().addingTimeInterval(Self.closeGraceSeconds)
            while process.isRunning, Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning {
                signal(SIGKILL)
            }
        }

        continuation.yield(.ended(error))
        continuation.finish()
    }

    /// Signal the server, or its whole group when it has one.
    private func signal(_ number: Int32) {
        let inGroup = state.withLock { $0.inOwnProcessGroup }
        if inGroup {
            kill(-process.processIdentifier, number)
        } else {
            kill(process.processIdentifier, number)
        }
    }
}

/// The server could not be started at all.
enum MCPTransportLaunchError: Error, Equatable {
    case couldNotStart(command: String, reason: String)
}
