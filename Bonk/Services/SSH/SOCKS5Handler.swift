//
//  SOCKS5Handler.swift
//  Bonk
//
//  SOCKS5 protocol handler for dynamic port forwarding.
//

import Citadel
import NIO
import NIOSSH

/// Handles SOCKS5 protocol for dynamic port forwarding.
final class SOCKS5Handler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let clientBox: SSHClientBox
    private var state: State = .handshake

    enum State {
        case handshake
        case request
        case connected
    }

    init(client: SSHClient) {
        clientBox = SSHClientBox(client)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)

        switch state {
        case .handshake:
            handleHandshake(context: context, buffer: &buffer)
        case .request:
            handleRequest(context: context, buffer: &buffer)
        case .connected:
            break
        }
    }

    private func handleHandshake(context: ChannelHandlerContext, buffer: inout ByteBuffer) {
        guard let version = buffer.readInteger(as: UInt8.self),
              version == 5,
              let nMethods = buffer.readInteger(as: UInt8.self) else
        {
            context.close(promise: nil)
            return
        }

        buffer.moveReaderIndex(forwardBy: Int(nMethods))

        var response = context.channel.allocator.buffer(capacity: 2)
        response.writeInteger(UInt8(5))
        response.writeInteger(UInt8(0))
        context.write(wrapOutboundOut(response), promise: nil)
        context.flush()

        state = .request
    }

    private func handleRequest(context: ChannelHandlerContext, buffer: inout ByteBuffer) {
        guard let version = buffer.readInteger(as: UInt8.self),
              version == 5,
              let cmd = buffer.readInteger(as: UInt8.self),
              buffer.readInteger(as: UInt8.self) != nil,
              let atyp = buffer.readInteger(as: UInt8.self) else
        {
            context.close(promise: nil)
            return
        }

        guard cmd == 0x01 else {
            sendError(context: context, reply: 0x07)
            return
        }

        guard let host = parseHost(from: &buffer, atyp: atyp, context: context) else {
            return
        }

        guard let port = buffer.readInteger(as: UInt16.self) else {
            context.close(promise: nil)
            return
        }

        connectToTarget(host: host, port: port, context: context)
    }

    private func parseHost(from buffer: inout ByteBuffer, atyp: UInt8, context: ChannelHandlerContext) -> String? {
        switch atyp {
        case 0x01:
            guard let byte1 = buffer.readInteger(as: UInt8.self),
                  let byte2 = buffer.readInteger(as: UInt8.self),
                  let byte3 = buffer.readInteger(as: UInt8.self),
                  let byte4 = buffer.readInteger(as: UInt8.self) else
            {
                context.close(promise: nil)
                return nil
            }
            return "\(byte1).\(byte2).\(byte3).\(byte4)"
        case 0x03:
            guard let len = buffer.readInteger(as: UInt8.self),
                  let domain = buffer.readString(length: Int(len)) else
            {
                context.close(promise: nil)
                return nil
            }
            return domain
        case 0x04:
            var parts: [String] = []
            for _ in 0 ..< 8 {
                guard let part = buffer.readInteger(as: UInt16.self) else {
                    context.close(promise: nil)
                    return nil
                }
                parts.append(String(part, radix: 16))
            }
            return parts.joined(separator: ":")
        default:
            sendError(context: context, reply: 0x08)
            return nil
        }
    }

    private func connectToTarget(host: String, port: UInt16, context: ChannelHandlerContext) {
        do {
            let settings = try SSHChannelType.DirectTCPIP(
                targetHost: host,
                targetPort: Int(port),
                originatorAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0)
            )

            let channel = context.channel
            nonisolated(unsafe) let ctx = context
            nonisolated(unsafe) let selfRef = self

            Task {
                do {
                    let sshChannel = try await clientBox.client.createDirectTCPIPChannel(using: settings) { sshCh in
                        sshCh.eventLoop.makeSucceededVoidFuture()
                    }

                    var reply = channel.allocator.buffer(capacity: 10)
                    reply.writeInteger(UInt8(5))
                    reply.writeInteger(UInt8(0))
                    reply.writeInteger(UInt8(0))
                    reply.writeInteger(UInt8(1))
                    reply.writeInteger(UInt32(0))
                    reply.writeInteger(UInt16(0))
                    ctx.write(selfRef.wrapOutboundOut(reply), promise: nil)
                    ctx.flush()

                    let localToSSH = DataPipeHandler(target: sshChannel)
                    let sshToLocal = DataPipeHandler(target: channel)

                    channel.pipeline.addHandler(localToSSH, position: .last).whenComplete { _ in }
                    sshChannel.pipeline.addHandler(sshToLocal, position: .last).whenComplete { _ in }

                    selfRef.state = .connected
                } catch {
                    selfRef.sendError(context: ctx, reply: 0x05)
                }
            }
        } catch {
            sendError(context: context, reply: 0x05)
        }
    }

    private func sendError(context: ChannelHandlerContext, reply: UInt8) {
        var response = context.channel.allocator.buffer(capacity: 10)
        response.writeInteger(UInt8(5))
        response.writeInteger(reply)
        response.writeInteger(UInt8(0))
        response.writeInteger(UInt8(1))
        response.writeInteger(UInt32(0))
        response.writeInteger(UInt16(0))
        context.write(wrapOutboundOut(response), promise: nil)
        context.flush()
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }
}
