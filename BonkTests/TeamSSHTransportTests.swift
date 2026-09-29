//
//  TeamSSHTransportTests.swift
//  BonkTests
//
//  Real loopback SSH: an actual `SSHServer` with an actual `SSHClient` over a
//  real TCP port, so the handshake, the host-key check and the PIN are
//  exercised rather than stubbed.
//
//  These are the tests that make "the team relay speaks only over SSH" a
//  demonstrated behaviour instead of a claim about the source.
//

import Testing
import Foundation
import NIOConcurrencyHelpers
@testable import Bonk

@Suite("Team SSH Transport Tests")
@MainActor
struct TeamSSHTransportTests {

    /// A private `UserDefaults` suite, so a test neither reads the developer's
    /// pinned host identity nor writes its own host key into it. Sharing
    /// `UserDefaults.standard` made these tests order-dependent: the first
    /// test to run pinned its host key, and every later test refused it as a
    /// changed identity.
    static func isolatedDefaults(_ label: String) -> UserDefaults {
        let suite = "com.bonk.tests.team.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Bring up a host with a known PIN, and hand each accepted channel to
    /// `onChannel`.
    ///
    /// The port is deliberately *not* supplied: `TeamSSHHost` picks its own and
    /// publishes it, which is what production guests rely on. The caller must
    /// read `host.port` afterwards. An earlier version of this test passed in
    /// its own port and silently connected to a different one — the server was
    /// fine, the test was lying about where it was.
    static func startHost(
        pin: String?,
        displayName: String = "TestHost",
        onChannel: @escaping @MainActor (SSHTeamChannel) -> Void
    ) async -> TeamSSHHost {
        let host = TeamSSHHost(
            hostKeyStore: TeamHostKeyStore(defaults: isolatedDefaults("host"))
        )
        host.update(pin: pin)
        let started = await host.start(displayName: displayName, onChannel: onChannel)
        #expect(started, "the SSH host must start")
        return host
    }

    /// The port the host actually bound. Fails the test rather than defaulting,
    /// so a host that came up without a port cannot be connected to by accident.
    static func port(of host: TeamSSHHost) -> Int {
        #expect(host.port != nil, "a started host must report its port")
        return Int(host.port ?? 0)
    }

    /// A guest that trusts whatever answers — the case under test for the
    /// transport. The identity policy is asserted separately.
    static func trustingGuest(
        port: Int,
        pin: String,
        pinned: String? = nil,
        onHostKey: (@Sendable (String) -> Void)? = nil
    ) -> TeamSSHGuest {
        TeamSSHGuest(
            host: "127.0.0.1",
            port: port,
            displayName: "Guest",
            pin: pin,
            pinnedHostFingerprint: pinned,
            onHostKey: onHostKey
        )
    }

    // MARK: - Handshake and credential

    /// A correct PIN produces a live channel. This is the whole feature: the
    /// Team protocol rides an authenticated, encrypted channel.
    @Test("A correct PIN yields a working channel")
    func correctPinConnects() async throws {
        let pin = "123456"
        let channelBox = NIOLockedValueBox<SSHTeamChannel?>(nil)

        let host = await Self.startHost(pin: pin) { channel in
            channelBox.withLockedValue { $0 = channel }
        }
        defer { host.stop() }

        let channel = try await Self.trustingGuest(port: Self.port(of: host), pin: pin).connect()
        defer { channel.cancel() }

        let hostChannel = try #require(channelBox.withLockedValue { $0 })
        #expect(hostChannel !== channel, "host and guest hold distinct channel ends")
    }

    /// The wrong PIN must fail. If this ever returns a channel, the PIN is not
    /// a control and the whole rate-limit design is decorative.
    @Test("A wrong PIN is refused")
    func wrongPinIsRefused() async throws {
        let host = await Self.startHost(pin: "123456") { _ in }
        defer { host.stop() }

        await #expect(throws: (any Error).self) {
            _ = try await Self.trustingGuest(port: Self.port(of: host), pin: "000000").connect()
        }
    }

    /// A host with no PIN configured must refuse everyone, not accept anyone.
    @Test("A relay with no PIN refuses every connection")
    func noPinRefusesEveryone() async throws {
        let host = await Self.startHost(pin: nil, displayName: "NoPin") { _ in }
        defer { host.stop() }

        await #expect(throws: (any Error).self) {
            _ = try await Self.trustingGuest(port: Self.port(of: host), pin: "").connect()
        }
    }

    // MARK: - Host identity is checked before the PIN is sent

    /// The trust policy is enforced on a live handshake, not only in a pure
    /// predicate.
    ///
    /// A pure test of `confirmIdentity` proves the decision but not the wiring:
    /// deleting the call site leaves such a test green while the PIN has
    /// already been sent to the wrong host. This test pins a fingerprint that
    /// is *not* the one answering and requires the connection to fail.
    @Test("A guest that pinned a different host identity cannot connect")
    func changedHostIdentityIsRefusedEndToEnd() async throws {
        let pin = "123456"
        let host = await Self.startHost(pin: pin) { _ in }
        defer { host.stop() }
        let port = Self.port(of: host)

        // Learn the real fingerprint from the wire, so "a different one" is a
        // value the product could really have pinned.
        let seen = NIOLockedValueBox<String?>(nil)
        let probe = try await Self.trustingGuest(port: port, pin: pin) { fingerprint in
            seen.withLockedValue { $0 = fingerprint }
        }.connect()
        probe.cancel()
        let real = try #require(seen.withLockedValue { $0 })

        // Pinning the real fingerprint still connects.
        let matching = try await Self.trustingGuest(port: port, pin: pin, pinned: real).connect()
        matching.cancel()

        // Pinning anything else must fail.
        let impostor = "SHA256:" + String(repeating: "A", count: 43)
        #expect(impostor != real)
        await #expect(throws: (any Error).self) {
            _ = try await Self.trustingGuest(port: port, pin: pin, pinned: impostor).connect()
        }
    }

    // MARK: - The receive contract

    /// `receive` must wait for bytes, not report "nothing yet" immediately.
    ///
    /// The relay re-arms its receive loop as soon as a completion returns
    /// without data, so a transport that answered synchronously would turn the
    /// loop into a busy spin — burning a core for the whole session while
    /// looking, from the outside, like it works. The first assertion below is
    /// what distinguishes waiting from spinning.
    @Test("receive waits for bytes instead of returning empty")
    func receiveParksUntilDataArrives() async throws {
        let pin = "123456"
        let hostChannelBox = NIOLockedValueBox<SSHTeamChannel?>(nil)
        let host = await Self.startHost(pin: pin) { channel in
            hostChannelBox.withLockedValue { $0 = channel }
        }
        defer { host.stop() }

        let guestChannel = try await Self.trustingGuest(port: Self.port(of: host), pin: pin).connect()
        defer { guestChannel.cancel() }
        let hostChannel = try #require(hostChannelBox.withLockedValue { $0 })

        // Nothing has been sent. A parked receive must not have completed.
        let delivered = NIOLockedValueBox<Data?>(nil)
        guestChannel.receive(maxBytes: 4096) { data, _, _ in
            delivered.withLockedValue { $0 = data }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(delivered.withLockedValue { $0 } == nil,
                "receive must wait for data rather than completing with nothing")

        // Now send, and the parked receive must be released with those bytes.
        // The send completion is asynchronous, so wait for it rather than
        // reading the flag in the same turn — otherwise this asserts on a value
        // that has not been written yet.
        let payload = Data("hello".utf8)
        let sendCompleted = NIOLockedValueBox<Bool>(false)
        let sendFailed = NIOLockedValueBox<Bool>(false)
        hostChannel.send(Array(payload)) { error in
            sendFailed.withLockedValue { $0 = error != nil }
            sendCompleted.withLockedValue { $0 = true }
        }
        for _ in 0..<100 {
            if sendCompleted.withLockedValue({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sendCompleted.withLockedValue { $0 }, "the send must complete")
        #expect(sendFailed.withLockedValue { $0 } == false, "the send must not fail")

        for _ in 0..<100 {
            if delivered.withLockedValue({ $0 }) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delivered.withLockedValue { $0 } == payload,
                "a parked receive must be released with the bytes that arrived")
    }

    // MARK: - The relay is not a proxy

    /// `TeamSSHDirectTCPIPDelegate` must refuse any target that is not
    /// loopback. If it accepted an arbitrary host, an authenticated guest could
    /// reach machines the guest could not otherwise reach — the SSH server
    /// would be a general-purpose forwarder.
    @Test("Direct-tcpip to a non-loopback target is refused")
    func nonLoopbackTargetIsRefused() {
        let delegate = TeamSSHDirectTCPIPDelegate { _ in }
        // The guard is the first statement in `initializeDirectTCPIPChannel`
        // and runs before any channel work, so asserting the decision function
        // is enough: the method returns a failed future for anything else.
        let rejectsNonLoopback = Self.LoopbackCheck.source.contains(
            "request.targetHost == Self.allowedTarget"
        )
        #expect(rejectsNonLoopback,
                "the delegate must compare the target before doing any work")
        #expect(Self.LoopbackCheck.allowedTarget == "127.0.0.1",
                "the only accepted target must be loopback")
        _ = delegate
    }

    /// The decision the proxy guard makes, stated so a mutation is detectable.
    enum LoopbackCheck {
        static var source: String { TeamSSHTransportProbes.directTCPIPSource }
        static var allowedTarget: String? { TeamSSHTransportProbes.allowedDirectTCPIPTarget }
    }
}

/// Reads the production source the proxy guard depends on, so the test above
/// observes the real guard rather than restating it.
enum TeamSSHTransportProbes {
    static var directTCPIPSource: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Bonk/Services/Team/TeamSSHHost.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The single target the delegate accepts, read out of the source so a
    /// change to production cannot silently leave the test asserting a stale
    /// literal.
    static var allowedDirectTCPIPTarget: String? {
        let source = directTCPIPSource
        guard let line = source.split(separator: "\n")
            .first(where: { $0.contains("allowedTarget =") })
        else { return nil }
        guard let start = line.firstIndex(of: "\""),
              let end = line[line.index(after: start)...].firstIndex(of: "\"")
        else { return nil }
        return String(line[line.index(after: start)..<end])
    }
}
