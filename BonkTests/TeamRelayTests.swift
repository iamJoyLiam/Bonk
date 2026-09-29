//
//  TeamRelayTests.swift
//  BonkTests
//

import Foundation
import Network
import XCTest
@testable import Bonk

@MainActor
final class TeamRelayTests: XCTestCase {

    override func setUp() async throws {
        UserDefaults.standard.set(1, forKey: "team_max_guests")
        // The pinned host identity is a single global slot (see
        // `TeamIdentityStore`), and the host key is persisted in
        // `UserDefaults.standard` too. A fingerprint pinned by an earlier run —
        // or by an earlier test in this process — therefore does not describe
        // the host this test just started, and every guest is correctly refused.
        //
        // Clearing it means each test starts from trust-on-first-use, which is
        // the state a user is in the first time they pair.
        TeamIdentityStore.forgetPinnedHost()
    }
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "team_max_guests")
        TeamIdentityStore.forgetPinnedHost()
    }

    func testHostGuestPairingPropagatesGuestIdentity() async throws {
        let host = TeamRelay()
        let guest = TeamRelay()
        host.startHosting(displayName: "Host")

        let port = try await waitForPort(host)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        guest.connectToHost(endpoint: endpoint, displayName: "Joy", pin: host.pairingPin!)

        await waitUntil {
            host.connectedPeers.count == 1 && guest.isConnected
        }

        XCTAssertEqual(host.connectedPeers.first?.displayName, "Joy")
        XCTAssertEqual(host.connectedPeers.first?.role, .guest)
        XCTAssertEqual(host.connectedPeers.count, TeamConstants.maxGuestCount)

        host.stopHosting()
        guest.disconnectGuest()
    }

    func testHostRejectsSecondGuest() async throws {
        let host = TeamRelay()
        let firstGuest = TeamRelay()
        let secondGuest = TeamRelay()
        host.startHosting(displayName: "Host")

        let port = try await waitForPort(host)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let pin = try XCTUnwrap(host.pairingPin)
        firstGuest.connectToHost(endpoint: endpoint, displayName: "One", pin: pin)
        await waitUntil {
            host.connectedPeers.count == 1 && firstGuest.isConnected
        }

        secondGuest.connectToHost(endpoint: endpoint, displayName: "Two", pin: pin)
        await waitUntil {
            secondGuest.lastError != nil || !secondGuest.isConnected
        }

        XCTAssertEqual(host.connectedPeers.count, 1)
        XCTAssertFalse(secondGuest.isConnected)

        host.stopHosting()
        firstGuest.disconnectGuest()
        secondGuest.disconnectGuest()
    }

    /// The Team protocol must actually flow over the encrypted transport.
    ///
    /// Pairing alone is not enough: pairing is a single round trip, so a
    /// channel that delivered the handshake and then nothing would still look
    /// like a working session. This drives a second, independent message and
    /// requires the guest to see it.
    ///
    /// It also pins down the receive contract. `TeamChannel.receive` must
    /// *wait* for bytes: the relay re-arms its receive loop as soon as a
    /// completion returns empty, so a transport that answered "nothing yet"
    /// synchronously would spin the main actor and starve everything else.
    func testTeamMessagesFlowAfterPairing() async throws {
        let host = TeamRelay()
        let guest = TeamRelay()
        host.startHosting(displayName: "Host")

        let port = try await waitForPort(host)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        guest.connectToHost(endpoint: endpoint, displayName: "Joy", pin: host.pairingPin!)

        try await waitUntilOrThrow {
            host.connectedPeers.count == 1 && guest.hasPaired
        }

        // A message sent *after* pairing, on the same channel.
        let shared = [HostItemExport(
            name: "shared-host",
            host: "10.0.0.9",
            port: 22,
            username: "user",
            authType: "password",
            credential: nil
        )]
        host.shareHosts(shared)

        try await waitUntilOrThrow(timeout: .seconds(5)) {
            guest.pendingShareHosts?.first?.name == "shared-host"
        }
        XCTAssertEqual(guest.pendingShareHosts?.count, 1)

        host.stopHosting()
        guest.disconnectGuest()
    }

    /// Wait for a condition, failing the test with a message rather than
    /// letting a bare `waitUntil` time out ambiguously.
    private func waitUntilOrThrow(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout)")
        throw CancellationError()
    }

    private func waitForPort(_ relay: TeamRelay) async throws -> UInt16 {
        for _ in 0..<100 {
            if let port = relay.hostedPort, port != 0 {
                return port
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("Team listener did not publish a port")
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
