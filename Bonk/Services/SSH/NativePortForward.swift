//
//  NativePortForward.swift
//  Bonk — v3.3 Native Local Forward stub (Citadel directTCPIP + Network.framework)
//  Full data-plane glue lands after M6; this keeps the hybrid API shippable.
//
#if os(macOS)
import Citadel
import Foundation
import Network
import NIO
import NIOSSH
import os.log

/// Local port forward via Native engine (stub — establishes listener, data pump TODO).
final class NativePortForward: @unchecked Sendable {
    private let client: SSHClient
    private let localHost: String
    private let localPort: Int
    private let remoteHost: String
    private let remotePort: Int
    private var listener: NWListener?
    private let log = Logger(subsystem: "com.bonk", category: "NativeForward")

    init(client: SSHClient, localHost: String, localPort: Int, remoteHost: String, remotePort: Int) {
        self.client = client
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: UInt16(localPort)) else { throw PortForwardError.serviceUnavailable }
        listener = try NWListener(using: params, on: port)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.log.info("[NativeForward] incoming \(conn.endpoint.debugDescription, privacy: .public) — data pump TODO, falling back to OpenSSH for now")
            conn.cancel()
            // TODO v3.3 full: createDirectTCPIPChannel + NWConnection ↔ Channel glue (see earlier draft)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.log.info("[NativeForward] listening \(self?.localHost ?? ""):\(self?.localPort ?? 0) → \(self?.remoteHost ?? ""):\(self?.remotePort ?? 0) (stub)")
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        log.info("[NativeForward] stopped \(self.localHost):\(self.localPort)")
    }
}

// NativeSSHSession exposes client internally for forward (friend file, same module)
extension NativeSSHSession {
    var forwardClient: SSHClient { client }
    func makeLocalForward(localHost: String, localPort: Int, remoteHost: String, remotePort: Int) throws -> NativePortForward {
        NativePortForward(client: client, localHost: localHost, localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
    }
}
#endif
