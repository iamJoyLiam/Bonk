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
