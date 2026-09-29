//
//  TeamTransportAbstractionTests.swift
//  BonkTests
//
//  The team relay must be reachable only over SSH.
//
//  This file replaces an earlier version that asserted the opposite — that the
//  transport abstraction left the plaintext `NWConnection` and the in-band PIN
//  untouched. That assertion was correct while SSH was still being built and
//  would have failed the build if the migration had been done in one step, but
//  keeping it would now forbid the very property we want.
//
//  The tests below state the *production* property, and are written to fail
//  loudly if someone reintroduces a plaintext path or moves authentication out
//  of the handshake.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Team Transport Abstraction Tests")
struct TeamTransportAbstractionTests {

    // MARK: - The plaintext path is structurally gone

    /// No production Team file may name a plaintext socket type.
    ///
    /// This is the test that would have caught a "half-migrated" relay: a
    /// commit where `startHosting` still built an `NWListener` while SSH was
    /// wired up alongside it. Two code paths, one of them unencrypted, and
    /// every green test still passing.
    @Test("No Team production file constructs a plaintext socket")
    func noPlaintextSocketInProduction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Bonk/Services/Team")

        let offenders = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .compactMap { name -> String? in
                let source = try String(
                    contentsOf: root.appendingPathComponent(name),
                    encoding: .utf8
                )
                // Strip line comments so prose about NWListener is not a hit.
                let code = source
                    .split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                if code.contains("NWListener(") || code.contains("NWConnection(") {
                    return name
                }
                return nil
            }
        #expect(offenders.isEmpty,
                "plaintext socket construction in Team production code: \(offenders)")
    }

    /// `NWConnection` must not satisfy `TeamChannel`.
    ///
    /// This is a compile-time fact, so it cannot be asserted at runtime — any
    /// expression of the form "this value is a `TeamChannel`" would simply fail
    /// to build if the conformance were gone, which is the point. What *can* be
    /// asserted is that the conformance's source is absent, which is why the
    /// check below is part of `noPlaintextSocketInProduction` rather than a
    /// separate test: `extension NWConnection: TeamChannel` would be written in
    /// Team production code, and that scan is already done.
    @Test("The plaintext conformance is not reintroduced")
    func noPlaintextChannelConformance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Bonk/Services/Team/TeamTransport.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        #expect(!source.contains(": TeamChannel"),
                "a conformance to TeamChannel must not return to TeamTransport")
    }

    // MARK: - The PIN is the transport credential, not a protocol field

    /// The challenge must not carry the PIN.
    ///
    /// The PIN is consumed by SSH user authentication. Re-encoding it in the
    /// Team protocol would put the credential on the wire a second time, inside
    /// a message an unauthenticated reader could have captured had the
    /// transport ever been plaintext.
    @Test("pairingChallenge does not carry the PIN")
    func pairingChallengeCarriesNoPin() throws {
        let peer = TeamPeer(id: UUID(), displayName: "Guest", role: .guest)
        let message = TeamMessage.pairingChallenge(peer: peer, nonce: "n1")

        let encoded = try JSONEncoder().encode(message)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(json["pin"] == nil,
                "the PIN must not be re-encoded into the Team protocol")
    }

    /// A wrong PIN must be refused, and a right one accepted — the properties
    /// the in-band check used to have, now owned by `TeamPINAuthenticator`.
    @Test("The PIN is verified by the transport authenticator, not the protocol")
    func pinLivesInTheAuthenticator() {
        let authenticator = TeamPINAuthenticator()
        let now = Date()

        #expect(authenticator.evaluate(
            peer: "a", presentedPin: "000000", expectedPin: "123456", now: now
        ) == .reject(remaining: 4))

        #expect(authenticator.evaluate(
            peer: "a", presentedPin: "123456", expectedPin: "123456", now: now
        ) == .accept)
    }
}
