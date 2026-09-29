//
//  TeamSSHHost.swift
//  Bonk
//
//  The encrypted team host: an SSH server whose only accepted channel type is
//  a direct-tcpip request back to loopback, which is then handed to the
//  existing Team protocol handler.
//
//  Why this shape rather than a second port:
//
//  A guest that opens a direct-tcpip channel to the host's own loopback gets
//  a channel the SSH server terminates locally. `TeamSSHDirectTCPIPDelegate`
//  never dials the requested target, so the relay cannot be used as a proxy
//  to reach hosts the guest could not already reach. Everything after the
//  handshake is the existing framed-JSON protocol, unchanged.
//
//  The credential is the team PIN, presented as SSH user authentication
//  (see `TeamSSHAuthDelegate`). Reaching the Team handler therefore *already*
//  means the PIN was accepted, which is why the Team protocol does not carry
//  a second copy of it.
//

import Citadel
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import os.log

/// Hosts the team relay over SSH and advertises it via Bonjour.
@MainActor
final class TeamSSHHost {
    fileprivate static let logger = Logger(subsystem: "com.bonk", category: "TeamSSHHost")

    private let authenticator: TeamPINAuthenticator
    private let hostKeyStore: TeamHostKeyStore
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private var server: SSHServer?
    /// Bonjour advertisement. Kept separate from the listener because
    /// `BonjourService` is iOS-only, and an `NWListener` would re-open a
    /// plaintext socket — exactly what this type exists to remove.
    private var advertisedService: NetService?

    /// The PIN, mirrored into a lock the SSH event loop can read without
    /// hopping actors. Written only from the main actor (see `update(pin:)`).
    private let pinBox = NIOLockedValueBox<String?>(nil)

    /// Port the SSH server bound, published once it is listening.
    private(set) var port: UInt16?
    private(set) var isRunning = false

    init(authenticator: TeamPINAuthenticator = TeamPINAuthenticator(),
         hostKeyStore: TeamHostKeyStore = TeamHostKeyStore()) {
        self.authenticator = authenticator
        self.hostKeyStore = hostKeyStore
    }

    /// Publish the PIN that SSH user authentication will demand.
    ///
    /// Passing `nil` means "no PIN configured", which makes every
    /// authentication attempt fail — a relay with no PIN must not be
    /// reachable, rather than reachable by anyone.
    func update(pin: String?) {
        pinBox.withLockedValue { $0 = pin }
    }

    /// Start the SSH server and publish it as `_bonk-team._tcp`.
    ///
    /// - Parameters:
    ///   - displayName: Bonjour service name.
    ///   - onChannel: receives each accepted Team channel. Called on the main
    ///     actor; the caller owns the channel from then on.
    /// - Returns: `true` when the relay is listening and advertised.
    @discardableResult
    func start(
        displayName: String,
        onChannel: @escaping @MainActor (SSHTeamChannel) -> Void
    ) async -> Bool {
        guard !isRunning else { return true }
        guard let hostKey = hostKeyStore.loadOrCreateHostKey() else {
            Self.logger.error("No usable host key; refusing to host")
            return false
        }
        guard let bound = TeamPortPicker.availablePort() else {
            Self.logger.error("No free TCP port for the team relay")
            return false
        }

        let delegate = TeamSSHAuthDelegate(
            authenticator: authenticator,
            expectedPin: { [pinBox] in pinBox.withLockedValue { $0 } }
        )
        do {
            let server = try await SSHServer.host(
                host: "0.0.0.0",
                port: Int(bound),
                hostKeys: [hostKey],
                authenticationDelegate: delegate,
                group: group
            )
            server.enableDirectTCPIP(
                withDelegate: TeamSSHDirectTCPIPDelegate { channel in
                    onChannel(channel)
                }
            )
            self.server = server
            isRunning = true
            port = bound
            advertise(displayName: displayName, on: bound)
            return true
        } catch {
            Self.logger.error("SSH server failed to start: \(error.localizedDescription)")
            isRunning = false
            return false
        }
    }

    func stop() {
        advertisedService?.stop()
        advertisedService = nil
        port = nil
        isRunning = false
        pinBox.withLockedValue { $0 = nil }
        let server = server
        self.server = nil
        guard let server else { return }
        // `SSHServer` is not `Sendable`, and `close()` is async, so closing it
        // from the main actor is a cross-isolation send. The box asserts the
        // invariant: the server is created on this main actor, closed once, and
        // never touched again afterwards.
        let handle = UncheckedSendable(server)
        let closeGroup = group
        Task {
            try? await handle.value.close()
            try? await closeGroup.shutdownGracefully()
        }
    }

    /// Forget a peer's failure history — called once a guest pairs, so a peer
    /// that failed twice and then succeeded starts clean.
    func resetFailureBudget(for peer: String) {
        authenticator.reset(peer: peer)
    }

    // MARK: - Bonjour

    /// `BonjourService` is iOS-only, and an `NWListener` would re-open a
    /// plaintext socket — exactly what this type exists to remove. So the
    /// advertisement is a bare `NetService`: it publishes the SSH port and
    /// opens no socket of its own.
    private func advertise(displayName: String, on bound: UInt16) {
        let service = NetService(
            domain: TeamConstants.serviceDomain,
            type: TeamConstants.serviceType,
            name: displayName,
            port: Int32(bound)
        )
        service.delegate = servicePublisher
        service.publish()
        advertisedService = service
    }

    private let servicePublisher = NetServiceDelegateBridge()

}

/// Carries a value across an isolation boundary the compiler cannot prove
/// safe, with the invariant stated at the point of use.
///
/// Only for values whose concurrency is already established by construction
/// (created on one actor, used on one actor, never shared).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Observes Bonjour publication so a failure is visible rather than silent.
@MainActor
private final class NetServiceDelegateBridge: NSObject, NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        TeamSSHHost.logger.info("Advertised team relay over Bonjour")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        TeamSSHHost.logger.error("Bonjour publish failed: \(errorDict)")
    }
}

/// Accepts *only* the loopback direct-tcpip channel that carries the Team
/// protocol, and refuses everything else.
///
/// This is the trust boundary that keeps the relay from being a proxy: the
/// requested target is never dialled. A non-loopback request is refused
/// explicitly so the refusal is a decision, not an accident of routing.
struct TeamSSHDirectTCPIPDelegate: DirectTCPIPDelegate {
    private static let allowedTarget = "127.0.0.1"
    private static let logger = Logger(subsystem: "com.bonk", category: "TeamDirectTCPIP")
    private let onChannel: @Sendable @MainActor (SSHTeamChannel) -> Void

    init(onChannel: @escaping @Sendable @MainActor (SSHTeamChannel) -> Void) {
        self.onChannel = onChannel
    }

    func initializeDirectTCPIPChannel(
        _ channel: Channel,
        request: SSHChannelType.DirectTCPIP,
        context: SSHContext
    ) -> EventLoopFuture<Void> {
        guard request.targetHost == Self.allowedTarget else {
            Self.logger.error("Refusing direct-tcpip to \(request.targetHost)")
            return channel.eventLoop.makeFailedFuture(TeamChannelError.unavailable)
        }
        let teamChannel = SSHTeamChannel(channel: channel)
        teamChannel.startReceiving()
        Task { @MainActor in onChannel(teamChannel) }
        return channel.eventLoop.makeSucceededVoidFuture()
    }
}
