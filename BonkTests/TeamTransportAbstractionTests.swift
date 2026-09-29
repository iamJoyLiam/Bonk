//
//  TeamTransportAbstractionTests.swift
//  BonkTests — the transport abstraction must be behaviour-preserving.
//
//  This commit replaces the concrete `NWConnection` with `any TeamChannel`
//  and changes nothing else. The security properties of the team session must
//  therefore be identical before and after:
//
//    plaintext TCP + PIN + existing pairing semantics
//
//  The tests below state that as an explicit invariant rather than leaving it
//  implicit, because the failure mode they guard against is a specific and
//  easy mistake: during a transport migration, deleting the old
//  authentication check *before* the new one is wired up. That produces a
//  commit which is green, builds, and has no PIN check at all.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Team Transport Abstraction Tests")
struct TeamTransportAbstractionTests {

    /// The abstraction must not have changed what the host accepts: pairing
    /// still requires the PIN.
    @Test("Pairing still requires the PIN on the wire")
    func pairingStillCarriesThePin() {
        let peer = TeamPeer(id: UUID(), displayName: "Guest", role: .guest)
        // If the transport migration had moved the PIN into another layer,
        // this would have become `pairingChallenge(peer:nonce:)` and the
        // transport would be accepting unauthenticated peers.
        let message = TeamMessage.pairingChallenge(pin: "123456", peer: peer, nonce: "n1")
        guard case let .pairingChallenge(pin, _, _) = message else {
            Issue.record("pairingChallenge must still carry the PIN")
            return
        }
        #expect(pin == "123456")
    }

    /// A PIN that does not match must not pair. The host handler is the single
    /// place this is enforced, so assert the guard is present in the source
    /// rather than asserting a code path that needs a live peer.
    @Test("The host still rejects a PIN mismatch")
    func hostStillChecksThePin() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Bonk/Services/Team/TeamRelay+Host.swift"),
            encoding: .utf8
        )
        #expect(source.contains("pin == pairingPin"),
                "the host must compare the presented PIN before pairing a peer")
        #expect(source.contains("recordPairingFailure()"),
                "a PIN mismatch must count against the retry budget")
        #expect(source.contains("rejectHostConnection(peerConnectionID, reason: L.t(.tmWrongPin))"),
                "a PIN mismatch must terminate the connection")
    }

    /// The pairing gate is unchanged: an unpaired peer still cannot inject
    /// session state, and pinning still requires an acceptance that echoes
    /// the guest's own nonce.
    @Test("Pairing gate semantics are unchanged")
    func pairingGateUnchanged() {
        let sessionID = TeamSessionID(tabID: UUID(), paneID: UUID())
        let gate = TeamRelay.PairingGate.self
        #expect(gate.isUntrusted(.terminalOutput(sessionID: sessionID, payload: "x"), hasPaired: false))
        #expect(gate.isUntrusted(.shareHosts(hosts: []), hasPaired: false))
        // A pairing acceptance must reach the validator (it is the only
        // message that can establish pairing), but a *wrong* one must not
        // result in a paired guest.
        #expect(!gate.isUntrusted(
            .pairingAccepted(
                nonce: "wrong",
                hostFingerprint: "SHA256:a",
                host: TeamPeer(id: UUID(), displayName: "H", role: .host, isDriver: true)
            ),
            hasPaired: false
        ))
        #expect(
            TeamRelay.PairingGate.evaluateAcceptance(
                nonce: "wrong",
                expectedNonce: "expected",
                presentedFingerprint: "SHA256:a",
                pinnedFingerprint: nil
            ) == .rejectReplay
        )
    }

    /// The abstraction is real: the relay's channel storage no longer names a
    /// concrete `NWConnection`, so reverting to a plaintext socket requires an
    /// explicit change rather than happening by accident.
    @Test("Relay channels are typed as TeamChannel, not NWConnection")
    func relayUsesTheAbstraction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in [
            "Bonk/Services/Team/TeamRelay.swift",
            "Bonk/Services/Team/TeamRelay+Host.swift",
            "Bonk/Services/Team/TeamRelay+Guest.swift",
            "Bonk/Services/Team/TeamRelay+Messaging.swift",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(file),
                encoding: .utf8
            )
            #expect(!source.contains(": NWConnection"),
                   "\(file) still stores a concrete NWConnection")
            #expect(!source.contains("to connection: NWConnection"),
                   "\(file) still exposes NWConnection in its API")
        }
    }
}
