//
//  SSHTeamChannel.swift
//  Bonk
//
//  `TeamChannel` over an SSH direct-tcpip channel.
//
//  This is the encrypted path. A guest opens an SSH session to the host —
//  authenticated with the team PIN, with the host key already verified by
//  `HostKeyValidator` *inside* the handshake, before the PIN is sent — then
//  requests a direct-tcpip channel. Everything the Team protocol carries
//  travels inside that channel, so a LAN observer sees only ciphertext and an
//  attacker who injects bytes fails the SSH integrity check.
//
//  Reading uses a `ChannelInboundHandler` rather than a promise-based read:
//  `Channel.read()` is fire-and-forget in NIO, and buffering the inbound bytes
//  through a handler is what lets `TeamMessageFramer` keep its existing
//  pull-based shape without racing the event loop.
//

import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import os.log

/// A `TeamChannel` backed by one SSH direct-tcpip channel.
final class SSHTeamChannel: TeamChannel {
    private static let logger = Logger(subsystem: "com.bonk", category: "SSHTeamChannel")

    private let channel: Channel
    private let closed = NIOLockedValueBox<Bool>(false)
    /// Read side: bytes not yet consumed, plus a parked `receive`.
    private let inbound = NIOLockedValueBox(InboundState())

    /// A byte buffer plus at most one parked `receive`.
    ///
    /// `receive` must *wait*, not poll. The relay's receive loop calls itself
    /// again as soon as a completion returns without data, so a channel that
    /// answered "nothing yet" synchronously would re-enter forever and starve
    /// the main actor — the session would hang rather than fail.
    private struct InboundState {
        var buffer = Data()
        /// `TeamChannel` has a single reader, so there is never more than one.
        var waiter: (@Sendable (Data?, Bool, Error?) -> Void)?
    }

    var onStateChange: (@Sendable (TeamChannelState) -> Void)?

    init(channel: Channel) {
        self.channel = channel
    }

    /// The loopback target the guest requests. The SSH server terminates the
    /// channel locally, so this never causes a second outbound connection.
    private static let directTCPIPTarget = "127.0.0.1"

    func activate() {
        // The channel is already live once DirectTCPIPClient hands it over.
        onStateChange?(.ready)
    }

    /// Start buffering inbound bytes for `receive(maxBytes:)`.
    func startReceiving() {
        // Capture the (Sendable) box rather than `self`, so the closures
        // crossing into NIO's event loop stay free of a non-Sendable capture.
        let inbound = inbound
        let closed = closed
        let handler = TeamInboundHandler(
            onData: { data in
                // Deliver straight to a parked reader, and only buffer when
                // nobody is waiting.
                let waiter = inbound.withLockedValue { state -> (@Sendable (Data?, Bool, Error?) -> Void)? in
                    guard let parked = state.waiter else {
                        state.buffer.append(data)
                        return nil
                    }
                    state.waiter = nil
                    return parked
                }
                waiter?(data, false, nil)
            },
            onFinish: {
                closed.withLockedValue { $0 = true }
                // A parked reader must be released, or the receive loop waits
                // forever on a channel that has already ended.
                let waiter = inbound.withLockedValue { state -> (@Sendable (Data?, Bool, Error?) -> Void)? in
                    let parked = state.waiter
                    state.waiter = nil
                    return parked
                }
                waiter?(nil, true, nil)
            }
        )
        channel.pipeline.addHandler(handler)
        channel.read()
    }

    func send(_ bytes: [UInt8], completion: @escaping @Sendable (Error?) -> Void) {
        guard !closed.withLockedValue({ $0 }) else {
            completion(TeamChannelError.closed)
            return
        }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer).whenComplete { result in
            switch result {
            case .success: completion(nil)
            case let .failure(error): completion(error)
            }
        }
    }

    /// Yields buffered inbound bytes, or parks until some arrive.
    ///
    /// Completes with `isComplete == true` only once the channel has actually
    /// ended, so the relay's loop can tell "peer closed" from "not yet" — a
    /// distinction its re-arm depends on.
    func receive(maxBytes: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        enum Action {
            case deliver(Data?, Bool, Error?)
            case park
        }
        let action = inbound.withLockedValue { state -> Action in
            if !state.buffer.isEmpty {
                let data = state.buffer
                state.buffer = Data()
                return .deliver(data, false, nil)
            }
            if closed.withLockedValue({ $0 }) {
                return .deliver(nil, true, nil)
            }
            state.waiter = completion
            return .park
        }
        switch action {
        case let .deliver(data, complete, error): completion(data, complete, error)
        case .park: break
        }
    }

    func cancel() {
        closed.withLockedValue { $0 = true }
        // Release a parked reader so the receive loop stops waiting.
        let waiter = inbound.withLockedValue { state -> (@Sendable (Data?, Bool, Error?) -> Void)? in
            let parked = state.waiter
            state.waiter = nil
            return parked
        }
        waiter?(nil, true, nil)
        channel.close(promise: nil)
    }
}

/// Opens `TeamChannel`s over a guest's authenticated SSH session.
///
/// `@unchecked Sendable` and an instance (not a static factory) because
/// `SSHClient` is not `Sendable`. The unchecked conformance asserts the same
/// invariant `NativePortForward` asserts: this type is only ever touched from
/// the single task that owns the client, and it adds no independent mutable
/// state of its own. Do not call `open` concurrently for the same factory.
final class TeamSSHChannelFactory: @unchecked Sendable {
    private let client: SSHClient

    init(client: SSHClient) {
        self.client = client
    }

    /// Open a direct-tcpip channel to the host's own team port.
    ///
    /// The target is loopback by construction: the SSH server terminates the
    /// channel itself, so a guest cannot use this to reach an arbitrary host
    /// through the relay's server.
    func open(hostPort: Int) async throws -> SSHTeamChannel {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let settings = SSHChannelType.DirectTCPIP(
            targetHost: "127.0.0.1",
            targetPort: Int(UInt16(clamping: hostPort)),
            originatorAddress: originator
        )
        let channel = try await client.createDirectTCPIPChannel(
            using: settings,
            initialize: { $0.eventLoop.makeSucceededVoidFuture() }
        )
        return SSHTeamChannel(channel: channel)
    }
}

/// Buffers inbound channel bytes for the owning `SSHTeamChannel` to pull from.
///
/// The bytes are consumed here rather than forwarded: nothing downstream in
/// the channel's pipeline wants them, and leaving them un-forwarded keeps the
/// relay's framer as the single reader. `context.read()` re-arms the read
/// interest, because NIO arms exactly one read per call.
private final class TeamInboundHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let onData: @Sendable (Data) -> Void
    private let onFinish: @Sendable () -> Void

    init(
        onData: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.onData = onData
        self.onFinish = onFinish
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let bytes = Data(buffer.readableBytesView)
        if !bytes.isEmpty { onData(bytes) }
        // NIO arms one read per call; re-arm to keep the loop alive.
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onFinish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onFinish()
        context.close(promise: nil)
    }
}

enum TeamChannelError: Error {
    case closed
    case unavailable
}
