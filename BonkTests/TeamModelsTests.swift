//
//  TeamModelsTests.swift
//  BonkTests
//

import Foundation
import XCTest
@testable import Bonk

final class TeamModelsTests: XCTestCase {

    func testMessageFramerHandlesSplitAndMultipleFrames() throws {
        var framer = TeamMessageFramer(maxFrameBytes: 1024, maxBufferBytes: 2048)
        let first = try framer.append(Data("{\"type\":\"heartbeat\"}\n{\"type\":\"".utf8))
        XCTAssertEqual(first.count, 1)

        let second = try framer.append(Data("heartbeat\"}\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(TeamMessage.self, from: first[0]), .heartbeat)
        XCTAssertEqual(try JSONDecoder().decode(TeamMessage.self, from: second[0]), .heartbeat)
    }

    func testMessageFramerRejectsUnterminatedBufferAboveLimit() {
        var framer = TeamMessageFramer(maxFrameBytes: 64, maxBufferBytes: 128)

        XCTAssertThrowsError(try framer.append(Data(repeating: 0x78, count: 129))) { error in
            XCTAssertEqual(error as? TeamProtocolError, .receiveBufferExceeded)
        }
    }

    func testTerminalMessageRoundTripPreservesSession() throws {
        let session = TeamSessionID(tabID: UUID(), paneID: UUID())
        let message = TeamMessage.terminalInput(sessionID: session, payload: "\u{1B}[A")

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: encoded)

        XCTAssertEqual(decoded, message)
    }

    func testPairingMessageRoundTripPreservesGuestIdentity() throws {
        let peer = TeamPeer(id: UUID(), displayName: "Joy", role: .guest)
        let message = TeamMessage.pairingChallenge(pin: "123456", peer: peer)

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: encoded)

        XCTAssertEqual(decoded, message)
    }

    func testPresenceRoundTripPreservesSharedSession() throws {
        let host = TeamPeer(id: UUID(), displayName: "Host", role: .host, isDriver: true)
        let session = TeamSessionID(tabID: UUID(), paneID: UUID())
        let snapshot = TeamPresenceSnapshot(
            hostPeer: host,
            guestPeers: [],
            driverPeerID: host.id,
            sharedSessionID: session
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TeamPresenceSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.sharedSessionID, session)
    }
}
