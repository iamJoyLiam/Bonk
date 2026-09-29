//
//  TeamPairingTrustTests.swift
//  BonkTests — guest-side trust boundary for team sessions.
//
//  A guest connects to a Bonjour-discovered endpoint, which any machine on the
//  LAN can advertise. The guest therefore treats the peer as unverified until
//  the host proves it validated our PIN, by echoing the nonce we generated.
//
//  These tests pin the decision logic: pairing is established by exactly one
//  message, the echoed nonce must match, and a host fingerprint that differs
//  from the pinned one is never accepted.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Team Pairing Trust Tests")
struct TeamPairingTrustTests {

    // MARK: - Host identity trust policy

    @Test("First-seen host is trusted and pinned")
    func firstSeenHostIsTrusted() {
        let decision = TeamHostIdentity.decide(presented: "SHA256:abc", pinned: nil)
        #expect(decision == .trustOnFirstUse)
    }

    @Test("An empty pinned value is treated as first use, not a match")
    func emptyPinnedIsFirstUse() {
        #expect(TeamHostIdentity.decide(presented: "SHA256:abc", pinned: "") == .trustOnFirstUse)
    }

    @Test("Matching fingerprint stays trusted")
    func matchingFingerprintTrusted() {
        #expect(TeamHostIdentity.decide(presented: "SHA256:abc", pinned: "SHA256:abc") == .trustedMatch)
    }

    @Test("Changed fingerprint is reported as a mismatch, never trusted")
    func changedFingerprintRejected() {
        let decision = TeamHostIdentity.decide(presented: "SHA256:evil", pinned: "SHA256:real")
        #expect(decision == .mismatch(pinned: "SHA256:real", presented: "SHA256:evil"))
        if case .trustedMatch = decision {
            Issue.record("a changed host identity must never be trusted")
        }
    }

    @Test("Fingerprint is derived deterministically from the seed")
    func fingerprintIsStableForSeed() {
        let seed = "fixed-seed-value"
        #expect(TeamHostIdentity.fingerprint(forSeed: seed) == TeamHostIdentity.fingerprint(forSeed: seed))
        #expect(TeamHostIdentity.fingerprint(forSeed: seed) != TeamHostIdentity.fingerprint(forSeed: "other-seed"))
        #expect(TeamHostIdentity.fingerprint(forSeed: seed).hasPrefix("SHA256:"))
    }

    @Test("Generated identities are unique")
    func generatedIdentitiesUnique() {
        let fingerprints = Set((0..<50).map { _ in TeamHostIdentity.generate().fingerprint })
        #expect(fingerprints.count == 50, "identity generation must not collide")
    }

    @Test("Pairing nonces are unique and long enough to resist guessing")
    func noncesAreUnique() {
        let nonces = Set((0..<200).map { _ in TeamRelay.makePairingNonce() })
        #expect(nonces.count == 200)
        #expect(nonces.allSatisfy { $0.count >= 16 })
    }

    // MARK: - Protocol shape

    @Test("pairingAccepted round-trips through Codable")
    func pairingAcceptedRoundTrips() throws {
        let host = TeamPeer(id: UUID(), displayName: "Host", role: .host, isDriver: true)
        let message = TeamMessage.pairingAccepted(
            nonce: "abc123",
            hostFingerprint: "SHA256:xyz",
            host: host
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: data)
        #expect(decoded == message)
    }

    @Test("pairingChallenge round-trips with its nonce")
    func pairingChallengeRoundTrips() throws {
        let peer = TeamPeer(id: UUID(), displayName: "Guest", role: .guest)
        let message = TeamMessage.pairingChallenge(pin: "123456", peer: peer, nonce: "nonce-1")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(TeamMessage.self, from: data)
        #expect(decoded == message)
    }

    @Test("A pairingAccepted without a nonce fails to decode")
    func pairingAcceptedRequiresNonce() {
        // A peer that cannot echo a nonce cannot be a host that received our
        // challenge; the decoder must not accept a record missing it.
        let json = """
        {"type":"pairingAccepted","hostFingerprint":"SHA256:x",\
        "host":{"id":"11111111-1111-1111-1111-111111111111","displayName":"H","role":"host","isDriver":true}}
        """
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(TeamMessage.self, from: Data(json.utf8))
        }
    }

    // MARK: - Pre-pairing gate

    @Test("Session traffic from an unpaired peer is refused")
    func unpairedPeerCannotInjectSessionState() {
        let sessionID = TeamSessionID(tabID: UUID(), paneID: UUID())
        let host = TeamPeer(id: UUID(), displayName: "Evil", role: .host, isDriver: true)
        let unpaired = TeamRelay.PairingGate.self

        // A peer that answers the connection but has not proved it validated
        // the PIN must not be able to drive the session.
        #expect(unpaired.isUntrusted(.terminalOutput(sessionID: sessionID, payload: "rm -rf /"), hasPaired: false))
        #expect(unpaired.isUntrusted(.notice(payload: "[Connected]"), hasPaired: false))
        #expect(unpaired.isUntrusted(.presenceSnapshot(snapshot: TeamPresenceSnapshot(
            hostPeer: host, guestPeers: [], driverPeerID: nil, sharedSessionID: sessionID
        )), hasPaired: false))
        #expect(unpaired.isUntrusted(.peerJoined(peer: host), hasPaired: false))
        // Credentials in a shareHosts payload are the worst case.
        #expect(unpaired.isUntrusted(.shareHosts(hosts: []), hasPaired: false))
        // Control messages must not be honoured either.
        #expect(unpaired.isUntrusted(.controlGrant(peerID: UUID()), hasPaired: false))
        #expect(unpaired.isUntrusted(.terminalInput(sessionID: sessionID, payload: "rm -rf /"), hasPaired: false))
    }

    @Test("Rejection, heartbeat and acceptance pass the pre-pairing gate")
    func controlMessagesPassGate() {
        let unpaired = TeamRelay.PairingGate.self
        // A real host refusing us must be able to tell us why.
        #expect(!unpaired.isUntrusted(.pairingRejected(reason: "wrong pin"), hasPaired: false))
        #expect(!unpaired.isUntrusted(.heartbeat, hasPaired: false))
        let host = TeamPeer(id: UUID(), displayName: "H", role: .host, isDriver: true)
        #expect(!unpaired.isUntrusted(
            .pairingAccepted(nonce: "n", hostFingerprint: "SHA256:x", host: host),
            hasPaired: false
        ))
    }

    @Test("Once paired, all traffic is allowed")
    func pairedPeerIsTrusted() {
        let sessionID = TeamSessionID(tabID: UUID(), paneID: UUID())
        let gate = TeamRelay.PairingGate.self
        #expect(!gate.isUntrusted(.terminalOutput(sessionID: sessionID, payload: "ok"), hasPaired: true))
        #expect(!gate.isUntrusted(.notice(payload: "x"), hasPaired: true))
    }

    // MARK: - Acceptance decision

    @Test("Acceptance requires the nonce we sent for this attempt")
    func acceptanceRequiresMatchingNonce() {
        let gate = TeamRelay.PairingGate.self
        #expect(gate.evaluateAcceptance(
            nonce: "n1", expectedNonce: "n1",
            presentedFingerprint: "SHA256:a", pinnedFingerprint: nil
        ) == .acceptAndPinFirstUse)
        // A recorded acceptance replayed against a fresh attempt fails.
        #expect(gate.evaluateAcceptance(
            nonce: "recorded", expectedNonce: "fresh",
            presentedFingerprint: "SHA256:a", pinnedFingerprint: nil
        ) == .rejectReplay)
    }

    @Test("Acceptance is impossible when no challenge is outstanding")
    func acceptanceRequiresOutstandingChallenge() {
        let gate = TeamRelay.PairingGate.self
        #expect(gate.evaluateAcceptance(
            nonce: "n", expectedNonce: nil,
            presentedFingerprint: "SHA256:a", pinnedFingerprint: nil
        ) == .rejectNoChallenge)
        #expect(gate.evaluateAcceptance(
            nonce: "n", expectedNonce: "",
            presentedFingerprint: "SHA256:a", pinnedFingerprint: nil
        ) == .rejectNoChallenge)
    }

    @Test("A matching pinned host is accepted without re-pinning")
    func acceptanceWithKnownHost() {
        let gate = TeamRelay.PairingGate.self
        #expect(gate.evaluateAcceptance(
            nonce: "n", expectedNonce: "n",
            presentedFingerprint: "SHA256:a", pinnedFingerprint: "SHA256:a"
        ) == .acceptAlreadyPinned)
    }

    @Test("A changed host is refused even when the nonce matches")
    func acceptanceRejectsChangedHostEvenWithGoodNonce() {
        let gate = TeamRelay.PairingGate.self
        // A correct nonce proves only that the peer got our challenge; it says
        // nothing about *which* machine answered.
        #expect(gate.evaluateAcceptance(
            nonce: "n", expectedNonce: "n",
            presentedFingerprint: "SHA256:evil", pinnedFingerprint: "SHA256:real"
        ) == .rejectIdentityChanged(presented: "SHA256:evil"))
    }

    // MARK: - Wiring

    /// Source-level guard: `hasPaired` must be set in exactly one place, the
    /// validated acceptance path. Any other assignment means ordinary traffic
    /// can mark a peer as the host again, which is the original bug.
    @Test("hasPaired is only set by the validated acceptance path")
    func hasPairedOnlySetAfterValidation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let guest = try String(
            contentsOf: root.appendingPathComponent("Bonk/Services/Team/TeamRelay+Guest.swift"),
            encoding: .utf8
        )
        // Count assignment statements, not prose: the doc comment quotes
        // `hasPaired = true` when describing the old bug.
        let assignments = guest.components(separatedBy: "\n").filter { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("hasPaired = true")
        }
        #expect(assignments.count == 1, "hasPaired must be assigned exactly once")
        // And that one assignment lives in acceptPairing, after the nonce and
        // fingerprint checks.
        let acceptStart = try #require(guest.range(of: "private func acceptPairing"))
        let tail = guest[acceptStart.lowerBound...]
        // Both checks now live in the pure decision function; what matters
        // here is that acceptPairing consults it, and that every rejection
        // path returns before pairing is set.
        let evaluation = try #require(tail.range(of: "PairingGate.evaluateAcceptance"))
        let paired = try #require(tail.range(of: "hasPaired = true"))
        #expect(evaluation.lowerBound < paired.lowerBound,
                "pairing set before the acceptance decision was evaluated")
        for caseName in ["case .rejectReplay", "case .rejectNoChallenge", "case let .rejectIdentityChanged"] {
            let branch = try #require(tail.range(of: caseName))
            #expect(branch.lowerBound < paired.lowerBound,
                    "\(caseName) must return before pairing is set")
        }
    }
}
