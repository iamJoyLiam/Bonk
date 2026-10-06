//
//  TeamSSHHostKeyPinningTests.swift
//  BonkTests
//
//  The learn → pin → verify lifecycle for the *SSH host key*, as opposed to
//  the Team identity fingerprint.
//
//  The bug this suite exists for: one UserDefaults slot held both, and
//  production fed the seed-derived identity half into the validator that
//  compares against a hash of the public key. Same `SHA256:` prefix, same
//  base64-without-padding body — so it looked plausible in review — but a seed
//  string can never hash to a public-key blob's hash. Every second and later
//  pairing therefore failed host-key verification, before the PIN was sent.
//
//  The tests drive the *production* path: `TeamRelay.connectToHost` against a
//  real `TeamSSHHost`, with the identity store injected so trust state is
//  chosen rather than inherited. A test that built its own `TeamSSHGuest`
//  would keep passing with the relay's wiring deleted, which is the trap the
//  ordering suite in `TeamSSHHostKeyOrderingTests` already demonstrates.
//

import Crypto
import Foundation
import Network
import NIOCore
import NIOSSH
import Testing
@testable import Bonk

@Suite("Team SSH Host Key Pinning Tests")
@MainActor
struct TeamSSHHostKeyPinningTests {

    // MARK: - The two fingerprints are different quantities

    /// The encoding being identical is exactly what made the slot confusion
    /// invisible. If this ever fails, the two surfaces have genuinely merged and
    /// the rest of this suite's premises need rechecking.
    @Test("The identity and SSH host key fingerprints are the same shape and different values")
    func identityAndHostKeyFingerprintsDiffer() throws {
        let seed = "a-team-identity-seed"
        let identity = TeamHostIdentity.fingerprint(forSeed: seed)
        let hostKey = try HostFingerprintFixture.fingerprint(for: Curve25519.Signing.PrivateKey().rawRepresentation)

        // Same encoding...
        #expect(identity.hasPrefix("SHA256:"))
        #expect(hostKey.hasPrefix("SHA256:"))
        // ...different quantities. A seed can never equal a public key's hash.
        #expect(identity != hostKey, "these must be distinct values, not the same measure twice")
    }

    /// The decisive property, stated as a fact about the hash: no seed produces
    /// the fingerprint of a given host key, and no host key produces a seed's.
    ///
    /// This is what made the production wiring wrong rather than merely
    /// confusing, so it is pinned down independently of any relay.
    @Test("No identity seed can ever be mistaken for a host key fingerprint")
    func noSeedMatchesAHostKey() throws {
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        let hostKey = try HostFingerprintFixture.fingerprint(for: key)
        for index in 0..<200 {
            let seed = "seed-\(index)"
            #expect(TeamHostIdentity.fingerprint(forSeed: seed) != hostKey)
        }
    }

    // MARK: - Slot separation

    @Test("The identity pin and the SSH host key pin are stored separately")
    func pinsDoNotCollide() {
        let defaults = makeIsolatedDefaults()
        let store = TeamIdentityStore(defaults: defaults)

        store.pinTeamIdentityFingerprint("SHA256:identity-value")
        #expect(store.pinnedTeamIdentityFingerprint() == "SHA256:identity-value")
        #expect(store.pinnedSSHHostKeyFingerprint() == nil,
                "pinning an identity must not populate the SSH host key slot")

        store.pinSSHHostKeyFingerprint("SHA256:ssh-key-value")
        #expect(store.pinnedSSHHostKeyFingerprint() == "SHA256:ssh-key-value")
        #expect(store.pinnedTeamIdentityFingerprint() == "SHA256:identity-value",
                "pinning a host key must not disturb the identity pin")
    }

    /// The recovery path has to exist, and it must forget *only* the SSH pin:
    /// a user clearing a changed host key is not asking to re-trust a
    /// different machine's identity.
    @Test("Forgetting the host key leaves the identity pin intact")
    func forgetClearsOnlyTheSSHPin() {
        let store = TeamIdentityStore(defaults: makeIsolatedDefaults())
        store.pinTeamIdentityFingerprint("SHA256:identity-value")
        store.pinSSHHostKeyFingerprint("SHA256:ssh-key-value")

        store.forgetPinnedHost()

        #expect(store.pinnedSSHHostKeyFingerprint() == nil)
        #expect(store.pinnedTeamIdentityFingerprint() == "SHA256:identity-value")
    }

    @Test("The two stores do not share UserDefaults with the host key store")
    func identityStoreIsIsolated() {
        let defaults = makeIsolatedDefaults()
        let identity = TeamIdentityStore(defaults: defaults)
        let hostKeys = TeamHostKeyStore(defaults: defaults)

        hostKeys.injectSeed(Data(repeating: 0x44, count: 32))
        identity.pinSSHHostKeyFingerprint("SHA256:ssh-key-value")

        // Neither surface may overwrite the other's bytes: a host key is a
        // secret-adjacent 32-byte seed, a pin is a hash string.
        #expect(hostKeys.loadOrCreateHostKey() != nil)
        #expect(identity.pinnedSSHHostKeyFingerprint() == "SHA256:ssh-key-value")
    }

    // MARK: - The lifecycle, through the production connect path

    /// First use learns the key the server actually presented, and stores *that*
    /// — not a locally derived value.
    ///
    /// This is the assertion the old wiring could not have passed: it stored
    /// whatever `onHostKey` handed over, so if `TeamRelay` stopped passing a
    /// validator-derived value the test goes red instead of quietly passing.
    @Test("First use pins the presented key, and the second connection succeeds")
    func secondConnectionToTheSameHostSucceeds() async throws {
        let defaults = makeIsolatedDefaults()
        let identityStore = TeamIdentityStore(defaults: defaults)

        let host = TeamRelay(
            store: TeamStore(),
            identityStore: TeamIdentityStore(defaults: makeIsolatedDefaults())
        )
        host.startHosting(displayName: "Host")
        let port = try await waitForPort(host)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        defer { host.stopHosting() }

        // --- First use: nothing pinned, TOFU accepts, and the key is learned.
        let firstGuest = TeamRelay(store: TeamStore(), identityStore: identityStore)
        firstGuest.connectToHost(endpoint: endpoint, displayName: "First", pin: host.pairingPin!)
        try await waitUntilOrThrow(label: "PIN-00 firstGuest.isConnected") { firstGuest.isConnected }
        let learned = try #require(identityStore.pinnedSSHHostKeyFingerprint(),
                                   "the first connection must pin the host key it accepted")
        #expect(learned.hasPrefix("SHA256:"))
        #expect(learned != identityStore.pinnedTeamIdentityFingerprint() ?? learned,
                "the SSH pin must be the public-key hash, not the identity fingerprint")
        firstGuest.disconnectGuest()

        // --- Second use: the same host, so verification must now *succeed*.
        //
        // This is the assertion that fails on the old code. It fed a
        // seed-derived pin to the validator, so this connection was refused
        // every single time after the first.
        let secondGuest = TeamRelay(store: TeamStore(), identityStore: identityStore)
        secondGuest.connectToHost(endpoint: endpoint, displayName: "Second", pin: host.pairingPin!)
        try await waitUntilOrThrow(label: "PIN-01 second connect reports an error") {
            if secondGuest.lastError != nil { Issue.record("second connection failed: \(secondGuest.lastError!)") }
            return secondGuest.isConnected
        }
        #expect(secondGuest.hasPaired, "a re-connect to a known host must pair again")
        secondGuest.disconnectGuest()
    }

    /// A *different* key on the same machine must be refused — and refused
    /// before the PIN leaves, which is the ordering invariant the other suite
    /// pins down. Here we additionally require that the trust store is not
    /// overwritten on refusal, so an attacker cannot walk the user into
    /// accepting them by retrying.
    @Test("A rotated host key is refused and the stored pin is not replaced")
    func rotatedHostKeyIsRefused() async throws {
        let identityStore = TeamIdentityStore(defaults: makeIsolatedDefaults())

        // Learn the honest host's key.
        let honest = TeamRelay(
            store: TeamStore(),
            identityStore: TeamIdentityStore(defaults: makeIsolatedDefaults())
        )
        honest.startHosting(displayName: "Host")
        let honestPort = try await waitForPort(honest)
        defer { honest.stopHosting() }

        let guest = TeamRelay(store: TeamStore(), identityStore: identityStore)
        guest.connectToHost(
            endpoint: .hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                port: NWEndpoint.Port(rawValue: honestPort)!),
            displayName: "First",
            pin: honest.pairingPin!
        )
        try await waitUntilOrThrow(label: "PIN-02 guest.isConnected") { guest.isConnected }
        let pinned = try #require(identityStore.pinnedSSHHostKeyFingerprint())
        guest.disconnectGuest()

        // Now answer on that port with a *different* key. A fresh relay uses
        // `TeamHostKeyStore`'s isolated defaults, so its key is provably not
        // the one we just pinned.
        // A bare `TeamSSHHost` with its own key store: the same server code the
        // relay runs, with a key that is provably not the pinned one.
        let impostorHost = TeamSSHHost(hostKeyStore: TeamHostKeyStore(defaults: makeIsolatedDefaults()))
        impostorHost.update(pin: honest.pairingPin)
        let impostorPort = try await startHost(impostorHost)
        defer { impostorHost.stop() }

        let refused = TeamRelay(store: TeamStore(), identityStore: identityStore)
        refused.connectToHost(
            endpoint: .hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                port: NWEndpoint.Port(rawValue: impostorPort)!),
            displayName: "Second",
            pin: honest.pairingPin!
        )
        try await waitUntilOrThrow(label: "PIN-03 refused.lastError != nil") { refused.lastError != nil }
        #expect(!refused.isConnected, "a host presenting an unpinned key must not be connected to")
        #expect(identityStore.pinnedSSHHostKeyFingerprint() == pinned,
                "a refused key must not replace the stored pin")
    }

    /// Recovery: after the user explicitly forgets a changed key, the next
    /// connection learns again. Without this the user is locked out with no
    /// action available — every connect fails before the PIN, so there is
    /// nothing on screen telling them what went wrong or how to fix it.
    @Test("After forgetting, a new host key is learned instead of refused forever")
    func forgetAllowsRelearning() async throws {
        let identityStore = TeamIdentityStore(defaults: makeIsolatedDefaults())

        let honest = TeamRelay(
            store: TeamStore(),
            identityStore: TeamIdentityStore(defaults: makeIsolatedDefaults())
        )
        honest.startHosting(displayName: "Host")
        let honestPort = try await waitForPort(honest)
        defer { honest.stopHosting() }

        let guest = TeamRelay(store: TeamStore(), identityStore: identityStore)
        guest.connectToHost(
            endpoint: .hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                port: NWEndpoint.Port(rawValue: honestPort)!),
            displayName: "First",
            pin: honest.pairingPin!
        )
        try await waitUntilOrThrow(label: "PIN-04 guest.isConnected") { guest.isConnected }
        let firstKey = try #require(identityStore.pinnedSSHHostKeyFingerprint())
        guest.disconnectGuest()

        // A second, differently-keyed host stands in for a rotated key.
        let rotated = TeamSSHHost(hostKeyStore: TeamHostKeyStore(defaults: makeIsolatedDefaults()))
        rotated.update(pin: honest.pairingPin)
        let rotatedPort = try await startHost(rotated)
        defer { rotated.stop() }

        let refused = TeamRelay(store: TeamStore(), identityStore: identityStore)
        refused.connectToHost(
            endpoint: .hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                port: NWEndpoint.Port(rawValue: rotatedPort)!),
            displayName: "Second",
            pin: honest.pairingPin!
        )
        try await waitUntilOrThrow(label: "PIN-05 refused.lastError != nil") { refused.lastError != nil }
        #expect(identityStore.pinnedSSHHostKeyFingerprint() == firstKey)

        // The user acts: forget, then retry.
        identityStore.forgetPinnedHost()
        let recovered = TeamRelay(store: TeamStore(), identityStore: identityStore)
        recovered.connectToHost(
            endpoint: .hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                port: NWEndpoint.Port(rawValue: rotatedPort)!),
            displayName: "Third",
            pin: honest.pairingPin!
        )
        try await waitUntilOrThrow(label: "PIN-06 recovered.lastError != nil || reco") { recovered.lastError != nil || recovered.isConnected }
        #expect(recovered.isConnected, "after an explicit forget the new key must be learnable")
        let newKey = try #require(identityStore.pinnedSSHHostKeyFingerprint())
        #expect(newKey != firstKey, "the rotated host must present a different key")
    }

    // MARK: - Wiring

    /// The relay must read the *SSH* slot for the validator and the *identity*
    /// slot for pairing. A source guard, and deliberately a second line of
    /// defence — the behaviour above is what proves enforcement; this only
    /// keeps the two from being silently reunited at a future edit.
    @Test("The relay reads each pin from its own slot")
    func relayReadsEachSlotSeparately() throws {
        let source = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/Team/TeamRelay.swift"),
            encoding: .utf8
        )
        let guestSource = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/Team/TeamRelay+Guest.swift"),
            encoding: .utf8
        )

        #expect(source.contains("pinnedHostFingerprint: identityStore.pinnedSSHHostKeyFingerprint()"),
                "the connector must be given the SSH host key pin")
        #expect(source.contains("onHostKey: identityStore.pinLearnedSSHHostKey()"),
                "the connector must learn and store the key it accepted")
        #expect(guestSource.contains("pinnedFingerprint: identityStore.pinnedTeamIdentityFingerprint()"),
                "the pairing gate must be given the identity pin")
        #expect(guestSource.contains("identityStore.pinTeamIdentityFingerprint(hostFingerprint)"),
                "the pairing gate must pin the identity fingerprint")

        // Neither store may reach for `UserDefaults.standard` directly, or the
        // injection these tests rely on stops existing.
        let storeSource = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/Team/TeamHostIdentity.swift"),
            encoding: .utf8
        )
        #expect(!storeSource.contains("UserDefaults.standard.string"),
                "the identity store must read its injected defaults")
        #expect(!storeSource.contains("UserDefaults.standard.set"),
                "the identity store must write its injected defaults")
    }

    // MARK: - Telling a changed key apart from any other failure

    /// Both directions, and neither inferred from the message text.
    ///
    /// Deny is the half that matters for safety: any other failure must not
    /// present the user with "trust this key", because accepting would discard
    /// a pin that was never actually contradicted.
    @Test("Only a changed host key is classified as one")
    func classifierRecognisesOnlyHostKeyFailures() throws {
        let mismatch = try #require(
            TeamHostKeyMismatchClassifier.classify(
                SSHServiceError.hostKeyMismatch(expected: "SHA256:old", received: "SHA256:new")
            )
        )
        #expect(mismatch == TeamHostKeyMismatch(pinned: "SHA256:old", presented: "SHA256:new"))

        // Unrelated failures must not offer the recovery.
        #expect(TeamHostKeyMismatchClassifier.classify(SSHServiceError.connectionFailed("refused")) == nil)
        #expect(TeamHostKeyMismatchClassifier.classify(SSHServiceError.reconnectExhausted(attempts: 3)) == nil)
        #expect(TeamHostKeyMismatchClassifier.classify(SSHServiceError.notConnected) == nil)
        #expect(TeamHostKeyMismatchClassifier.classify(CancellationError()) == nil)
    }

    /// The message must not be the trigger. `SSHServiceError`'s description is
    /// an unlocalized string in the error type; if the classifier keyed on it,
    /// a re-worded sentence would silently remove the user's only way out.
    @Test("Classification does not depend on the error's wording")
    func classificationIgnoresWording() throws {
        let error = SSHServiceError.hostKeyMismatch(expected: "a", received: "b")
        #expect(TeamHostKeyMismatchClassifier.classify(error) != nil)
        #expect(error.errorDescription?.isEmpty == false,
               "sanity: this error does carry a message, and is still classified by type")
    }

    /// End to end: a real connection to a host presenting a different key must
    /// surface as a *named* refusal carrying both fingerprints.
    ///
    /// This is the assertion that proves the relay's `catch` classifies at all;
    /// a pure function test would pass with the call site deleted.
    @Test("A refused connect is surfaced as a named mismatch, with both fingerprints")
    func refusedConnectIsSurfacedAsAMismatch() async throws {
        let identityStore = TeamIdentityStore(defaults: makeIsolatedDefaults())

        let honest = TeamRelay(
            store: TeamStore(),
            identityStore: TeamIdentityStore(defaults: makeIsolatedDefaults())
        )
        honest.startHosting(displayName: "Host")
        let honestPort = try await waitForPort(honest)
        defer { honest.stopHosting() }

        let guest = TeamRelay(store: TeamStore(), identityStore: identityStore)
        guest.connectToHost(endpoint: endpoint(honestPort), displayName: "First", pin: honest.pairingPin!)
        try await waitUntilOrThrow(label: "PIN-07 guest.isConnected") { guest.isConnected }
        let pinned = try #require(identityStore.pinnedSSHHostKeyFingerprint())
        guest.disconnectGuest()

        let rotated = TeamSSHHost(hostKeyStore: TeamHostKeyStore(defaults: makeIsolatedDefaults()))
        rotated.update(pin: honest.pairingPin)
        let rotatedPort = try await startHost(rotated)
        defer { rotated.stop() }

        let refused = TeamRelay(store: TeamStore(), identityStore: identityStore)
        refused.connectToHost(endpoint: endpoint(rotatedPort), displayName: "Second", pin: honest.pairingPin!)
        try await waitUntilOrThrow(label: "PIN-08 refused.hostKeyMismatch != nil") { refused.hostKeyMismatch != nil }

        let mismatch = try #require(refused.hostKeyMismatch)
        #expect(mismatch.pinned == pinned, "the refusal must name what we trusted")
        #expect(mismatch.presented.hasPrefix("SHA256:"))
        #expect(mismatch.presented != mismatch.pinned)
    }

    /// A refusal from an earlier attempt must not be re-reported by the next
    /// one: it is recomputed, not remembered.
    @Test("A stale mismatch does not survive into the next attempt")
    func staleMismatchIsClearedOnReconnect() async throws {
        let identityStore = TeamIdentityStore(defaults: makeIsolatedDefaults())

        let honest = TeamRelay(
            store: TeamStore(),
            identityStore: TeamIdentityStore(defaults: makeIsolatedDefaults())
        )
        honest.startHosting(displayName: "Host")
        let honestPort = try await waitForPort(honest)
        defer { honest.stopHosting() }

        let guest = TeamRelay(store: TeamStore(), identityStore: identityStore)
        guest.connectToHost(endpoint: endpoint(honestPort), displayName: "First", pin: honest.pairingPin!)
        try await waitUntilOrThrow(label: "PIN-09 guest.isConnected") { guest.isConnected }
        let pinned = try #require(identityStore.pinnedSSHHostKeyFingerprint())
        guest.disconnectGuest()

        let rotated = TeamSSHHost(hostKeyStore: TeamHostKeyStore(defaults: makeIsolatedDefaults()))
        rotated.update(pin: honest.pairingPin)
        let rotatedPort = try await startHost(rotated)
        defer { rotated.stop() }

        let refused = TeamRelay(store: TeamStore(), identityStore: identityStore)
        refused.connectToHost(endpoint: endpoint(rotatedPort), displayName: "Second", pin: honest.pairingPin!)
        try await waitUntilOrThrow(label: "PIN-10 refused.hostKeyMismatch != nil") { refused.hostKeyMismatch != nil }

        // Accept, then start the retry the user asked for.
        refused.acceptChangedHostKey()
        #expect(identityStore.pinnedSSHHostKeyFingerprint() == nil,
                "accepting must clear the pin, or the retry is refused again")

        // And the recovery has to actually work, not just clear state.
        refused.connectToHost(endpoint: endpoint(rotatedPort), displayName: "Third", pin: honest.pairingPin!)
        try await waitUntilOrThrow(label: "PIN-11 post-deadline connect resolves") {
            if refused.lastError != nil { Issue.record("recovery connect failed: \(refused.lastError!)") }
            return refused.isConnected
        }
        #expect(refused.hostKeyMismatch == nil)
        let relearned = try #require(identityStore.pinnedSSHHostKeyFingerprint())
        #expect(relearned != pinned, "the new key must be what is now pinned")
        refused.disconnectGuest()
    }

    /// The recovery action clears the SSH pin and nothing else.
    ///
    /// If it also dropped the identity pin, accepting a new host key would
    /// silently re-trust a different machine's identity — two trust surfaces,
    /// one user gesture.
    @Test("Accepting a new key does not discard the identity pin")
    func acceptingDoesNotDropTheIdentityPin() {
        let store = TeamIdentityStore(defaults: makeIsolatedDefaults())
        let relay = TeamRelay(store: TeamStore(), identityStore: store)
        store.pinTeamIdentityFingerprint("SHA256:identity-value")
        store.pinSSHHostKeyFingerprint("SHA256:ssh-key-value")
        relay.hostKeyMismatch = TeamHostKeyMismatch(pinned: "SHA256:ssh-key-value", presented: "SHA256:other")

        relay.acceptChangedHostKey()

        #expect(store.pinnedSSHHostKeyFingerprint() == nil)
        #expect(store.pinnedTeamIdentityFingerprint() == "SHA256:identity-value")
    }

    /// Accepting must not quietly open a connection, and must not erase the
    /// warning either.
    ///
    /// The action forgets and stops. If it reconnected on its own, the user
    /// would be connected to a machine they had only just been warned about,
    /// which is a different decision from the one they made. And "I accept this
    /// key" is not "this never happened" — the warning stays until a new
    /// attempt supersedes it, which is what clears it.
    @Test("Accepting only forgets the pin: no connection, warning retained")
    func acceptingOnlyForgets() async throws {
        let store = TeamIdentityStore(defaults: makeIsolatedDefaults())
        let relay = TeamRelay(store: TeamStore(), identityStore: store)
        store.pinSSHHostKeyFingerprint("SHA256:ssh-key-value")
        let mismatch = TeamHostKeyMismatch(pinned: "SHA256:ssh-key-value", presented: "SHA256:other")
        relay.hostKeyMismatch = mismatch

        relay.acceptChangedHostKey()
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.pinnedSSHHostKeyFingerprint() == nil)
        #expect(!relay.isConnected, "accepting a key must not open a session")
        #expect(relay.guestConnection == nil)
        #expect(relay.guestPeer == nil)
        #expect(relay.hostKeyMismatch == mismatch, "accepting is not the same as dismissing the warning")
    }

    /// The view has no behavioural test harness in this project — every view
    /// contract here is a source guard — so this only proves the recovery is
    /// *reachable*, not that it looks right. Stated plainly because the user
    /// needs to know which of the two claims is being made.
    @Test("The guest sheet offers the recovery when a key is refused")
    func guestSheetOffersRecovery() throws {
        let sheet = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Views/Team/TeamGuestSheet.swift"),
            encoding: .utf8
        )
        let relay = try String(
            contentsOf: SourceLocator.projectFile("Bonk/Services/Team/TeamRelay.swift"),
            encoding: .utf8
        )

        // Present only while a refusal is pending.
        #expect(sheet.contains("isPresented: Binding(get: { relay.hostKeyMismatch != nil }"))
        // The action must forget *before* retrying, and must be destructive so
        // it cannot read as the ordinary confirmation.
        let accept = try #require(sheet.range(of: "relay.acceptChangedHostKey()"))
        let retry = try #require(sheet.range(of: "relay.connectToHost"))
        #expect(accept.lowerBound < retry.lowerBound, "the pin must be dropped before the retry")
        #expect(sheet.contains("role: .destructive"))
        // Dismissing without choosing must leave the pin alone: "not now" is not
        // "trust this key".
        let cancel = try #require(sheet.range(of: "Button(i18n.t(.cancel), role: .cancel)"))
        #expect(cancel.lowerBound > accept.lowerBound)
        let cancelScope = String(sheet[cancel.upperBound...].prefix(200))
        #expect(!cancelScope.contains("acceptChangedHostKey"))
        #expect(!cancelScope.contains("forgetPinnedHost"))
        // Cancelling must not resend the PIN while the user is still reading.
        #expect(!cancelScope.contains("connectToHost"))
        // Both fingerprints must be shown: "the key changed" is not actionable
        // if the user cannot see what it changed from.
        #expect(sheet.contains("mismatch.pinned"))
        #expect(sheet.contains("mismatch.presented"))
        // The relay must actually do it, and must not do it unprompted.
        #expect(relay.contains("func acceptChangedHostKey()"))
        let body = relay[try #require(relay.range(of: "func acceptChangedHostKey()")).lowerBound...]
        let end = try #require(body.range(of: "\n    }"))
        let scope = String(body[..<end.lowerBound])
        #expect(!scope.contains("connectToHost"), "accepting must not open a connection by itself")
    }

    // MARK: - Helpers

    private func endpoint(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "com.bonk.tests.teamPin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitForPort(_ relay: TeamRelay) async throws -> UInt16 {
        for _ in 0..<200 {
            if let port = relay.hostedPort, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CancellationError()
    }

    private func startHost(_ host: TeamSSHHost) async throws -> UInt16 {
        let started = await host.start(displayName: "Impostor") { _ in }
        guard started, let port = host.port else { throw CancellationError() }
        return port
    }

    /// `label` is mandatory. A bare "condition not met within 8.0 seconds"
    /// cannot say *which* wait failed, and this suite has more than one per
    /// test — an unidentified timeout is not diagnosable evidence.
    private func waitUntilOrThrow(
        label: String,
        timeout: Duration = .seconds(8),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record(Comment(rawValue: "\(label): condition not met within \(timeout)"))
        throw CancellationError()
    }
}

/// Derives a host-key fingerprint the same way `HostKeyValidator` does, from a
/// known Curve25519 seed, so a test can state an expected value independently
/// of the code under test.
enum HostFingerprintFixture {
    static func fingerprint(for seed: Data) throws -> String {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        var buffer = ByteBuffer()
        NIOSSHPrivateKey(ed25519Key: privateKey).publicKey.write(to: &buffer)
        let digest = Crypto.SHA256.hash(data: Data(buffer.readableBytesView))
        let body = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(body)"
    }
}

enum SourceLocator {
    static func projectFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
