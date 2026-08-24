//
//  NativePortForward.swift
//  Bonk — v3.3 Native Local Forward (Citadel directTCPIP + Network.framework)
//  NWListener + directTCPIPChannel + manual NW↔NIO glue
//
#if os(macOS)
import Citadel
import Foundation
import Network
import NIO
import NIOCore
import NIOSSH
import os.log

/// Local port forward via Native engine — full data plane.
/// Listens on localHost:localPort via NWListener, for each inbound NWConnection
/// opens a SSH directTCPIP channel and pumps bytes both ways.
final class NativePortForward: @unchecked Sendable {
    private let client: SSHClient
    private let localHost: String
    private let localPort: Int
    private let remoteHost: String
    private let remotePort: Int
    private var listener: NWListener?
    private var bonds: [NWSSHForwardBond] = []
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.bonk", category: "NativeForward")
    private var running = false

    init(client: SSHClient, localHost: String, localPort: Int, remoteHost: String, remotePort: Int) {
        self.client = client
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func start() throws {
        guard !running else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        guard let port = NWEndpoint.Port(rawValue: UInt16(localPort)) else { throw PortForwardError.serviceUnavailable }
        // Bind to localHost if it's 127.0.0.1/localhost; otherwise 0.0.0.0 via NWListener default.
        listener = try NWListener(using: params, on: port)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleIncoming(conn)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log.info("[NativeForward] listening \(self?.localHost ?? ""):\(self?.localPort ?? 0) → \(self?.remoteHost ?? ""):\(self?.remotePort ?? 0)")
            case .failed(let err):
                self?.log.error("[NativeForward] listener failed: \(err.localizedDescription, privacy: .public)")
            case .cancelled:
                self?.log.info("[NativeForward] listener cancelled")
            default: break
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
        running = true
        log.info("[NativeForward] starting listener \(self.localHost):\(self.localPort) → \(self.remoteHost):\(self.remotePort)")
    }

    private func handleIncoming(_ nwConnection: NWConnection) {
        nwConnection.stateUpdateHandler = { [weak self, weak nwConnection] state in
            guard let self, let nwConnection else { return }
            switch state {
            case .ready:
                Task { await self.openChannel(for: nwConnection) }
            case .failed, .cancelled:
                nwConnection.cancel()
            default: break
            }
        }
        nwConnection.start(queue: .global(qos: .userInitiated))
    }

    private func openChannel(for nwConnection: NWConnection) async {
        do {
            let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let settings = SSHChannelType.DirectTCPIP(targetHost: remoteHost, targetPort: remotePort, originatorAddress: originator)
            // Initialize channel with SSH->NW bridge handler
            let bond: NWSSHForwardBond
            let channel: Channel = try await client.createDirectTCPIPChannel(using: settings) { channel in
                let handler = SSHToNWHandler(nwConnection: nwConnection)
                return channel.pipeline.addHandler(handler).flatMap {
                    channel.pipeline.addHandler(ErrorHandler())
                }
            }
            bond = NWSSHForwardBond(nwConnection: nwConnection, sshChannel: channel, log: log)
            lock.withLock { bonds.append(bond) }
            bond.start()
            log.info("[NativeForward] bond created local:\(self.localPort) → \(self.remoteHost):\(self.remotePort)")
            // Cleanup on close
            channel.closeFuture.whenComplete { [weak self, weak bond] _ in
                if let bond { self?.removeBond(bond) }
                nwConnection.cancel()
            }
        } catch {
            log.error("[NativeForward] createDirectTCPIPChannel failed: \(error.localizedDescription, privacy: .public)")
            nwConnection.cancel()
        }
    }

    private func removeBond(_ bond: NWSSHForwardBond) {
        lock.withLock { bonds.removeAll { $0 === bond } }
    }

    func stop() {
        guard running else { return }
        running = false
        listener?.cancel()
        listener = nil
        let snap = lock.withLock { bonds }
        for bond in snap { bond.close() }
        lock.withLock { bonds.removeAll() }
        log.info("[NativeForward] stopped \(self.localHost):\(self.localPort)")
    }

    deinit { listener?.cancel() }
}

// MARK: - Bond (NW ↔ SSH)

private final class NWSSHForwardBond: @unchecked Sendable {
    let nwConnection: NWConnection
    let sshChannel: Channel
    let log: Logger
    private var closed = false
    private let closeLock = NSLock()

    init(nwConnection: NWConnection, sshChannel: Channel, log: Logger) {
        self.nwConnection = nwConnection
        self.sshChannel = sshChannel
        self.log = log
    }

    func start() {
        // NW -> SSH loop
        receiveNext()
        // SSH -> NW is handled by SSHToNWHandler added before
        // NW close is already handled via Data.isComplete in receiveNext + channel closeFuture
    }

    private func receiveNext() {
        guard !closed else { return }
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if self.closed { return }
            if let error {
                self.log.debug("[NativeForward] NW receive error: \(error.localizedDescription, privacy: .public)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                let payload = data
                self.sshChannel.eventLoop.execute {
                    var buffer = self.sshChannel.allocator.buffer(capacity: payload.count)
                    buffer.writeBytes(payload)
                    self.sshChannel.writeAndFlush(buffer, promise: nil)
                }
            }
            if isComplete {
                self.sshChannel.eventLoop.execute {
                    self.sshChannel.close(mode: .output, promise: nil)
                }
                return
            }
            self.receiveNext()
        }
    }

    func close() {
        let shouldClose: Bool = closeLock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        nwConnection.cancel()
        sshChannel.eventLoop.execute { self.sshChannel.close(promise: nil) }
    }
}

// MARK: - Handler SSH -> NW

private final class SSHToNWHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let nwConnection: NWConnection
    init(nwConnection: NWConnection) { self.nwConnection = nwConnection }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = self.unwrapInboundIn(data)
        let count = buf.readableBytes
        guard count > 0 else { return }
        let data = Data(buf.readableBytesView)
        nwConnection.send(content: data, completion: .contentProcessed { _ in })
    }

    func channelInactive(context: ChannelHandlerContext) {
        nwConnection.cancel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        nwConnection.cancel()
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, case .inputClosed = channelEvent {
            nwConnection.send(content: nil, completion: .contentProcessed { _ in })
            // half close NW send side: NWConnection doesn't have half-close, just continue
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class ErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

extension NativeSSHSession {
    var forwardClient: SSHClient { client }
    func makeLocalForward(localHost: String, localPort: Int, remoteHost: String, remotePort: Int) throws -> NativePortForward {
        NativePortForward(client: client, localHost: localHost, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }
}
#endif
