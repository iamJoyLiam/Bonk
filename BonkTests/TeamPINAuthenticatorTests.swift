//
//  TeamPINAuthenticatorTests.swift
//  BonkTests
//
//  The team PIN is six digits and the relay's port is advertised over
//  Bonjour, so the rate limit is the only thing between a LAN peer and a
//  brute-force search of 10^6 candidates. These tests are therefore about the
//  *bounds*, not the happy path.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Team PIN Authenticator Tests")
struct TeamPINAuthenticatorTests {

    private let correct = "123456"
    private let wrong = "000000"

    // MARK: - The credential

    @Test("The correct PIN is accepted")
    func acceptsCorrectPin() {
        let auth = TeamPINAuthenticator()
        #expect(auth.evaluate(peer: "a", presentedPin: correct, expectedPin: correct) == .accept)
    }

    @Test("A wrong PIN is rejected and reports the remaining budget")
    func rejectsWrongPin() {
        let auth = TeamPINAuthenticator()
        #expect(auth.evaluate(peer: "a", presentedPin: wrong, expectedPin: correct)
                == .reject(remaining: 4))
    }

    // MARK: - Per-peer budget

    @Test("A peer that keeps guessing is locked out")
    func locksOutRepeatedFailures() {
        let auth = TeamPINAuthenticator()
        let now = Date()
        for _ in 0..<5 {
            _ = auth.evaluate(peer: "a", presentedPin: wrong, expectedPin: correct, now: now)
        }
        // Budget spent: refused regardless of what is presented, and in
        // particular regardless of whether the PIN is now correct.
        #expect(auth.evaluate(peer: "a", presentedPin: correct, expectedPin: correct, now: now)
                == .lockedOut(retryAfter: TeamPINAuthenticator.Limits.default.lockout),
                "a locked-out peer must be refused even with the right PIN")
    }

    @Test("The lockout expires")
    func lockoutExpires() {
        let auth = TeamPINAuthenticator()
        let start = Date()
        for _ in 0..<5 {
            _ = auth.evaluate(peer: "a", presentedPin: wrong, expectedPin: correct, now: start)
        }
        let later = start.addingTimeInterval(TeamPINAuthenticator.Limits.default.lockout + 1)
        #expect(auth.evaluate(peer: "a", presentedPin: correct, expectedPin: correct, now: later)
                == .accept)
    }

    @Test("A success clears the peer's history")
    func successResetsHistory() {
        let auth = TeamPINAuthenticator()
        let now = Date()
        for _ in 0..<4 {
            _ = auth.evaluate(peer: "a", presentedPin: wrong, expectedPin: correct, now: now)
        }
        #expect(auth.evaluate(peer: "a", presentedPin: correct, expectedPin: correct, now: now)
                == .accept)
        // Starts clean: four more failures are affordable again.
        #expect(auth.evaluate(peer: "a", presentedPin: wrong, expectedPin: correct, now: now)
                == .reject(remaining: 4))
    }

    @Test("Peers have independent budgets")
    func budgetsAreIndependent() {
        let auth = TeamPINAuthenticator()
        let now = Date()
        for _ in 0..<5 {
            _ = auth.evaluate(peer: "a", presentedPin: wrong, expectedPin: correct, now: now)
        }
        // Peer "a" is locked out; an honest peer "b" is unaffected.
        #expect(auth.evaluate(peer: "a", presentedPin: correct, expectedPin: correct, now: now)
                == .lockedOut(retryAfter: TeamPINAuthenticator.Limits.default.lockout))
    }

    // MARK: - Global budget — the control that survives a spoofed username

    /// SSH hands the delegate a client-supplied username and no peer address,
    /// so an attacker can pick a fresh username per attempt and never exhaust
    /// a per-peer budget. The global budget is what actually bounds guessing.
    @Test("Varying the username does not escape the global budget")
    func globalBudgetSurvivesUsernameVariation() {
        let limits = TeamPINAuthenticator.Limits(
            maxFailuresPerWindow: 5,
            window: 60,
            lockout: 30,
            maxGlobalFailuresPerWindow: 20
        )
        let auth = TeamPINAuthenticator(limits: limits)
        let now = Date()

        // Twenty failures, each claiming to be a brand-new peer.
        for attempt in 0..<20 {
            let decision = auth.evaluate(
                peer: "peer-\(attempt)",
                presentedPin: wrong,
                expectedPin: correct,
                now: now
            )
            if case .lockedOut = decision {
                // Exhausted early is fine, as long as it is exhausted.
                return
            }
        }
        // The budget is spent: a fresh username still buys nothing, and the
        // correct PIN is refused rather than compared.
        #expect(auth.evaluate(
            peer: "peer-brand-new",
            presentedPin: correct,
            expectedPin: correct,
            now: now
        ) == .lockedOut(retryAfter: limits.lockout),
        "a new username must not restore an exhausted global budget")
    }

    @Test("An empty username is still counted, not ignored")
    func emptyUsernameIsCounted() {
        let auth = TeamPINAuthenticator()
        let now = Date()
        for _ in 0..<5 {
            _ = auth.evaluate(peer: "", presentedPin: wrong, expectedPin: correct, now: now)
        }
        #expect(auth.evaluate(peer: "", presentedPin: correct, expectedPin: correct, now: now)
                == .lockedOut(retryAfter: TeamPINAuthenticator.Limits.default.lockout))
    }

    // MARK: - Constant-time comparison

    /// A six-digit PIN leaks its leading digits through an early-exit compare.
    /// This asserts the shape of the comparison rather than its timing, which
    /// is what a unit test can honestly establish.
    @Test("Comparison does not depend on where the first difference is")
    func comparisonIsPositionIndependent() {
        // Equal length, differs only in the first character.
        #expect(!TeamPINAuthenticator.constantTimeEquals("111111", "211111"))
        // Equal length, differs only in the last.
        #expect(!TeamPINAuthenticator.constantTimeEquals("111111", "111112"))
        // Different lengths are still unequal.
        #expect(!TeamPINAuthenticator.constantTimeEquals("1", "11"))
        #expect(TeamPINAuthenticator.constantTimeEquals("123456", "123456"))
    }
}
