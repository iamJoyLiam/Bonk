//
//  SFTPBackendFallbackTests.swift
//  BonkTests
//
//  Bonk has two SFTP transports and two independent host-key trust stores:
//
//    Citadel  -> PersistentHostKeyStore, UserDefaults "com.bonk.hostKeys"
//    OpenSSH  -> <App Support>/known_hosts, StrictHostKeyChecking=accept-new
//
//  So when the Citadel leg reports a host-key mismatch, retrying on OpenSSH is
//  not a retry of the *check* — OpenSSH consults a store that has never seen
//  this host, `accept-new` accepts the key Citadel just rejected, and writes it
//  to disk as trusted. A detected MITM becomes a silent one.
//
//  Why the two transports are a trust boundary, and where that is recorded
//  instead of asserted: Citadel keeps trust in `PersistentHostKeyStore`
//  (UserDefaults "com.bonk.hostKeys", keyed host:port — no delete method, so a
//  test cannot write to it without leaving residue in the user's defaults), and
//  OpenSSH keeps it in a file under Application Support that `ssh(1)` reads and
//  writes itself. Neither can see the other's decision. That is the property
//  that makes the leg counts below a security boundary rather than a preference.
//
//  These tests assert the sequence, not merely that an error surfaced. The
//  claim that matters is a count: after a host-key mismatch the second transport
//  must not have been attempted at all, because every harmful side effect — the
//  known_hosts write, the trust-store pollution, the second authentication
//  attempt — happens inside that leg. Asserting `error != nil` would pass
//  against the defect, which is exactly what the test that used to enshrine it
//  did (`SFTPMatrixLocalTests.testServiceCitadelToOpenSSHFallback`, itself
//  skipped without a bench SSH server on :2222).
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("SFTP backend fallback refuses to downgrade a host-key failure")
@MainActor
struct SFTPBackendFallbackTests {

    /// Counts how many times each leg ran, and what it was asked to fail with.
    ///
    /// `OSAllocatedUnfairLock` rather than `NSLock`: the counters are touched
    /// from async closures, and `NSLock.lock` is unavailable there.
    private final class Recorder: @unchecked Sendable {
        private let counts = OSAllocatedUnfairLock<[String: Int]>(uncheckedState: [:])
        private let citadelError: Error?
        private let openSSHError: Error?

        init(citadelError: Error?, openSSHError: Error? = nil) {
            self.citadelError = citadelError
            self.openSSHError = openSSHError
        }

        var citadelRuns: Int { counts.withLock { $0["citadel"] ?? 0 } }
        var openSSHRuns: Int { counts.withLock { $0["openSSH"] ?? 0 } }

        func citadel() async throws {
            counts.withLock { $0["citadel", default: 0] += 1 }
            if let citadelError { throw citadelError }
        }

        func openSSH() async throws {
            counts.withLock { $0["openSSH", default: 0] += 1 }
            if let openSSHError { throw openSSHError }
        }
    }

    private func legs(_ recorder: Recorder) -> SFTPBackendLegs {
        SFTPBackendLegs(citadel: { try await recorder.citadel() },
                        openSSH: { try await recorder.openSSH() })
    }

    private static let mismatch = SSHServiceError.hostKeyMismatch(
        expected: "SHA256:expected", received: "SHA256:attacker"
    )

    // MARK: - The gap

    /// The invariant. After a host-key mismatch the second transport must not run.
    @Test("a host-key mismatch never reaches the second transport")
    func mismatchDoesNotFallBack() async {
        let recorder = Recorder(citadelError: Self.mismatch)
        do {
            try await SFTPBackendFallback.run(legs(recorder))
            Issue.record("a host-key mismatch must not connect")
        } catch {
            // Expected. The point of the test is the counts below.
        }
        #expect(recorder.citadelRuns == 1, "the first transport was attempted")
        #expect(
            recorder.openSSHRuns == 0,
            "a rejected host key must not be retried against a different trust store"
        )
    }

    /// And the caller must be able to tell *why* it failed, or the UI will
    /// report a generic transport error for what is a security event.
    @Test("the host-key mismatch reaches the caller, not a generic error")
    func mismatchIsPropagatedUnchanged() async {
        let recorder = Recorder(citadelError: Self.mismatch)
        do {
            try await SFTPBackendFallback.run(legs(recorder))
            Issue.record("expected the mismatch to propagate")
        } catch let error as SSHServiceError {
            guard case .hostKeyMismatch(let expected, let received) = error else {
                Issue.record("expected hostKeyMismatch, got a different SSHServiceError")
                return
            }
            #expect(expected == "SHA256:expected")
            #expect(received == "SHA256:attacker")
        } catch {
            Issue.record("expected SSHServiceError.hostKeyMismatch")
        }
    }

    // MARK: - The failure the guard must not over-block

    /// Falling back is the point of the type. A transport failure is exactly
    /// when the other transport is worth trying, and a fix that blocked it would
    /// strand a user who would otherwise lose file access.
    @Test("a transport failure still falls back")
    func transportFailureFallsBack() async {
        let transportFailures: [Error] = [
            SSHServiceError.connectionFailed("connection refused"),
            SSHServiceError.notConnected,
            SFTPServiceError.notConnected,
        ]
        for failure in transportFailures {
            let recorder = Recorder(citadelError: failure)
            try? await SFTPBackendFallback.run(legs(recorder))
            #expect(recorder.openSSHRuns == 1, "a transport failure should still try the other transport")
        }
    }

    /// When the fallback itself fails, the error that explains what happened is
    /// the first one. The second is a consequence of the first.
    @Test("a failing fallback reports the original error")
    func failingFallbackReportsOriginalError() async {
        let recorder = Recorder(
            citadelError: SSHServiceError.connectionFailed("first"),
            openSSHError: SSHServiceError.connectionFailed("second")
        )
        do {
            try await SFTPBackendFallback.run(legs(recorder))
            Issue.record("expected a throw")
        } catch let error as SSHServiceError {
            guard case .connectionFailed(let message) = error else {
                Issue.record("expected connectionFailed")
                return
            }
            #expect(message == "first")
        } catch {
            Issue.record("expected SSHServiceError")
        }
    }

    /// Where OpenSSH does not exist there is nothing to fall back to, which is
    /// the same outcome as declining.
    @Test("no second transport means no fallback")
    func absentSecondTransport() async {
        let recorder = Recorder(citadelError: SSHServiceError.connectionFailed("refused"))
        let noOpenSSH = SFTPBackendLegs(citadel: { try await recorder.citadel() }, openSSH: nil)
        try? await SFTPBackendFallback.run(noOpenSSH)
        #expect(recorder.openSSHRuns == 0)
    }

    // MARK: - The decision itself

    @Test("only host-key trust failures refuse the fallback")
    func policyClassification() {
        #expect(SFTPBackendFallback.permitsFallback(SSHServiceError.connectionFailed("x")))
        #expect(SFTPBackendFallback.permitsFallback(SSHServiceError.notConnected))
        #expect(SFTPBackendFallback.permitsFallback(SSHServiceError.alreadyConnected))
        #expect(SFTPBackendFallback.permitsFallback(SFTPServiceError.notConnected))
        #expect(!SFTPBackendFallback.permitsFallback(Self.mismatch))
        #expect(SFTPBackendFallback.isHostKeyTrustFailure(Self.mismatch))
    }

    /// The mismatch also arrives as an opaque `NSError` from NIO on some paths,
    /// where the only signal is the text. A predicate that only understood the
    /// enum would let those through to the other trust store.
    @Test("an opaque NSError reporting a host-key failure is still recognised")
    func opaqueHostKeyErrorRecognised() {
        let opaque = NSError(
            domain: "NIOSSH",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "host key verification failed"]
        )
        #expect(SFTPBackendFallback.isHostKeyTrustFailure(opaque))
        #expect(!SFTPBackendFallback.permitsFallback(opaque))

        let unrelated = NSError(
            domain: "NIOSSH",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "connection refused"]
        )
        #expect(!SFTPBackendFallback.isHostKeyTrustFailure(unrelated))
        #expect(SFTPBackendFallback.permitsFallback(unrelated))
    }

}
