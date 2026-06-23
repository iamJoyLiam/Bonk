//
//  PortForwardService.swift
//  Bonk
//
//  Port forwarding service for SSH tunnels.
//

import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os.log

/// Wrapper to make SSHClient sendable for port forwarding.
private final class SSHClientBox: @unchecked Sendable {
    let client: SSHClient
    init(_ client: SSHClient) {
        self.client = client
    }
}

/// Port forwarding service for SSH tunnels.
@Observable @MainActor
final class PortForwardService {
    static let shared = PortForwardService()

    private let logger = Logger(subsystem: "com.bonk", category: "PortForward")

    /// Active port forwardings — stores the running Task.
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Whether any forwarding is active.
    var isActive: Bool {
        !activeTasks.isEmpty
    }

    /// SSH client reference for creating channels.
    private var sshClient: SSHClient?

    private init() {}

    // MARK: - Public API

    /// Set the SSH client to use for port forwarding.
    func setClient(_ client: SSHClient?) {
        sshClient = client
    }

    /// Start a port forwarding.
    func start(config: PortForward) async throws {
        guard activeTasks[config.id] == nil else {
            throw PortForwardError.alreadyRunning
        }

        guard let client = sshClient else {
            throw PortForwardError.serviceUnavailable
        }

        let clientBox = SSHClientBox(client)
        let task = Task {
            do {
                switch config.type {
                case .local:
                    try await startLocalForward(config: config, clientBox: clientBox)
                case .remote:
                    try await startRemoteForward(config: config, clientBox: clientBox)
                case .dynamic:
                    try await startDynamicForward(config: config, clientBox: clientBox)
                }
            } catch is CancellationError {
                // Expected when stopped
            } catch {
                await MainActor.run {
                    config.isActive = false
                    activeTasks.removeValue(forKey: config.id)
                }
            }
        }

        activeTasks[config.id] = task
        config.isActive = true
        logger.info("Started port forwarding: \(config.displayDescription)")
    }

    /// Stop a port forwarding.
    func stop(config: PortForward) {
        guard let task = activeTasks[config.id] else { return }
        task.cancel()
        activeTasks.removeValue(forKey: config.id)
        config.isActive = false
        logger.info("Stopped port forwarding: \(config.displayDescription)")
    }

    /// Stop all port forwardings.
    func stopAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    /// Get the status of a port forwarding.
    func status(for id: UUID) -> PortForwardStatus {
        activeTasks[id] != nil ? .running : .stopped
    }

    // MARK: - Local Forward (-L)

    /// Local port forwarding: listen on local port, forward through SSH to remote host.
    ///
    /// Equivalent to: `ssh -L localPort:remoteHost:remotePort user@host`
    private nonisolated func startLocalForward(config: PortForward, clientBox: SSHClientBox) async throws {
        let localHost = config.localHost
        let localPort = config.localPort
        let remoteHost = config.remoteHost
        let remotePort = config.remotePort

        let group = NIOPosix.MultiThreadedEventLoopGroup.singleton
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelInitializer { channel in
                do {
                    let settings = SSHChannelType.DirectTCPIP(
                        targetHost: remoteHost,
                        targetPort: remotePort,
                        originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    )

                    let promise = channel.eventLoop.makePromise(of: Void.self)
                    Task {
                        do {
                            _ = try await clientBox.client.createDirectTCPIPChannel(using: settings) { sshChannel in
                                let localToSSH = DataPipeHandler(target: sshChannel)
                                let sshToLocal = DataPipeHandler(target: channel)

                                return channel.pipeline.addHandler(localToSSH).flatMap {
                                    sshChannel.pipeline.addHandler(sshToLocal)
                                }
                            }
                            promise.succeed(())
                        } catch {
                            promise.fail(error)
                        }
                    }

                    return promise.futureResult
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let serverChannel = try await bootstrap.bind(host: localHost, port: localPort).get()

        // Keep alive until cancelled
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
                try? serverChannel.close().wait()
                continuation.resume()
            }
        }
    }

    // MARK: - Remote Forward (-R)

    /// Remote port forwarding: request remote server to listen, forward connections back.
    ///
    /// Equivalent to: `ssh -R remotePort:localHost:localPort user@host`
    private nonisolated func startRemoteForward(config: PortForward, clientBox: SSHClientBox) async throws {
        try await clientBox.client.runRemotePortForward(
            host: config.remoteHost,
            port: config.remotePort,
            forwardingTo: config.localHost,
            port: config.localPort
        ) { _ in }
    }

    // MARK: - Dynamic Forward (-D) — SOCKS5

    /// Dynamic port forwarding: SOCKS5 proxy server.
    ///
    /// Equivalent to: `ssh -D localPort user@host`
    private nonisolated func startDynamicForward(config: PortForward, clientBox: SSHClientBox) async throws {
        let localHost = config.localHost
        let localPort = config.localPort

        let group = NIOPosix.MultiThreadedEventLoopGroup.singleton
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelInitializer { channel in
                let handler = SOCKS5Handler(client: clientBox.client)
                return channel.pipeline.addHandler(handler)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let serverChannel = try await bootstrap.bind(host: localHost, port: localPort).get()

        // Keep alive until cancelled
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
                try? serverChannel.close().wait()
                continuation.resume()
            }
        }
    }
}

// MARK: - Status

enum PortForwardStatus {
    case stopped
    case running
    case error(String)
}

// MARK: - Errors

enum PortForwardError: LocalizedError {
    case alreadyRunning
    case notRunning
    case serviceUnavailable
    case socks5UnsupportedCommand(UInt8)
    case socks5ConnectionFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Port forwarding is already running"
        case .notRunning:
            "Port forwarding is not running"
        case .serviceUnavailable:
            "SSH connection not available for port forwarding"
        case let .socks5UnsupportedCommand(cmd):
            "SOCKS5 unsupported command: \(cmd)"
        case .socks5ConnectionFailed:
            "SOCKS5 failed to establish connection"
        }
    }
}

// MARK: - Data Pipe Handler

/// Bidirectional data pipe between two channels.
private final class DataPipeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let target: Channel
    private var closed = false

    init(target: Channel) {
        self.target = target
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        target.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !closed else { return }
        closed = true
        target.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !closed else { return }
        closed = true
        target.close(promise: nil)
        context.fireErrorCaught(error)
    }
}

