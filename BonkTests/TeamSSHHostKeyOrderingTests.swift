//
//  TeamSSHHostKeyOrderingTests.swift
//  BonkTests
//
//  The ordering invariant: a guest must not transmit the PIN to a host whose
//  key it has already pinned to something else.
//
//  Checking "the connection failed" is not enough. A post-handshake comparison
//  also fails the connection — after the credential has already been sent to
//  whoever answered. The only way to tell the two apart is to watch the
//  impostor's side: does its authentication delegate ever get asked for the
//  PIN?
//
//  So these tests run a *rogue* SSH server with a different host key and count
//  how many times its delegate is consulted. The count is the observable.
//

import Testing
import Foundation
import Citadel
import NIO
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
@testable import Bonk

/// A rogue host whose only difference is its identity.
@MainActor
final class RogueTeamHost {
    private(set) var server: SSHServer?
    /// How many times a credential was actually presented to this host.
    private let authAttempts = NIOLockedValueBox<Int>(0)
    private let authenticator = TeamPINAuthenticator()
    private let store: TeamHostKeyStore
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    init(seed: Data) {
        store = TeamHostKeyStore(defaults: {
            let suite = "com.bonk.tests.rogue.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }())
        // A different identity from the honest host's.
        store.injectSeed(seed)
    }

    var credentialsPresented: Int { authAttempts.withLockedValue { $0 } }

    func start(on port: Int, pin: String) async -> Bool {
        guard let key = store.loadOrCreateHostKey() else { return false }
        let delegate = TeamSSHAuthDelegate(
            authenticator: authenticator,
            expectedPin: { [authAttempts] in
                // Reaching this closure means the client sent us a password.
                authAttempts.withLockedValue { $0 += 1 }
                return pin
            }
        )
        do {
            let server = try await SSHServer.host(
                host: "0.0.0.0",
                port: port,
                hostKeys: [key],
                authenticationDelegate: delegate,
                group: group
            )
            self.server = server
            return true
        } catch {
            return false
        }
    }

    func stop() {
        let server = server
        self.server = nil
        let handle = server.map(UncheckedSendable.init)
        Task { [group] in
            try? await handle?.value.close()
            try? await group.shutdownGracefully()
        }
    }
}

@Suite("Team SSH Host Key Ordering Tests")
@MainActor
struct TeamSSHHostKeyOrderingTests {

    /// The impostor must never be asked for the credential.
    ///
    /// This is the test that distinguishes pre-auth verification from a
    /// post-hoc compare: both refuse the connection, but only one of them
    /// refuses *before* the PIN leaves the guest.
    @Test("The PIN is never presented to a host whose key changed")
    func pinIsNotSentToAnImpostor() async throws {
        let port = Int(TeamPortPicker.availablePort() ?? 0)
        let pin = "123456"

        // The identity the guest believes it is talking to: a *different* key
        // from the one the rogue will present.
        let believed = TeamHostKeyStore(defaults: {
            let suite = "com.bonk.tests.believed.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }())
        believed.injectSeed(Data(repeating: 0x11, count: 32))

        let rogue = RogueTeamHost(seed: Data(repeating: 0x22, count: 32))
        let rogueStarted = await rogue.start(on: port, pin: pin)
        #expect(rogueStarted, "the rogue host must start")
        defer { rogue.stop() }

        let guest = TeamSSHGuest(
            host: "127.0.0.1",
            port: port,
            displayName: "Guest",
            pin: pin,
            pinnedHostFingerprint: "SHA256:whatever-the-user-pinned"
        )

        // The connection must fail...
        await #expect(throws: (any Error).self) {
            _ = try await guest.connect()
        }
        // ...and it must have failed *before* the credential was sent.
        #expect(rogue.credentialsPresented == 0,
                """
                the impostor was asked for the PIN \(rogue.credentialsPresented) time(s); \
                host-key verification must happen inside the handshake, before authentication
                """)
    }

    /// The control case: when the guest has pinned nothing, the handshake
    /// proceeds and the PIN *is* sent. Without this, the test above would also
    /// pass if the guest simply never authenticates against anything.
    @Test("An unpinned guest does present its PIN (the control)")
    func unpinnedGuestAuthenticates() async throws {
        let port = Int(TeamPortPicker.availablePort() ?? 0)
        let pin = "123456"
        let rogue = RogueTeamHost(seed: Data(repeating: 0x33, count: 32))
        let rogueStarted = await rogue.start(on: port, pin: pin)
        #expect(rogueStarted, "the rogue host must start")
        defer { rogue.stop() }

        let guest = TeamSSHGuest(
            host: "127.0.0.1",
            port: port,
            displayName: "Guest",
            pin: pin,
            pinnedHostFingerprint: nil
        )
        // The rogue offers no direct-tcpip delegate, so channel setup fails —
        // but authentication has already happened by then, which is what this
        // test is measuring.
        _ = try? await guest.connect()
        #expect(rogue.credentialsPresented > 0,
                "an unpinned guest must reach the authentication step, or the test above proves nothing")
    }
}
