//
//  AuthRetryWaiterTests.swift
//  BonkTests
//
//  `requestAuthRetry` suspends its caller on a continuation until the auth
//  sheet answers. If that continuation is ever dropped instead of resumed, the
//  caller stays suspended for the lifetime of the process: the tab never
//  leaves its connecting state and nothing in the UI says why.
//
//  These tests exercise the real `SessionManager`, not a helper, because the
//  bug was never in the resume logic — it was in *which* continuation got
//  resumed. A test of an extracted registry would have stayed green while the
//  production wiring dropped waiters on the floor.
//

import Testing
import Foundation
import NIOConcurrencyHelpers
@testable import Bonk

@Suite("Auth Retry Waiter Tests")
@MainActor
struct AuthRetryWaiterTests {

    // MARK: - Helpers

    private func makeTab(_ name: String) -> TerminalTab {
        let host = HostItem(name: name, host: "10.0.0.1", port: 22, username: "u")
        return TerminalTab(hostItem: host)
    }

    private func result(_ password: String) -> SessionManager.AuthRetryResult {
        SessionManager.AuthRetryResult(
            password: password,
            privateKeyPEM: "",
            certificatePEM: "",
            secureEnclaveTag: nil,
            credentialID: nil,
            authType: .password
        )
    }

    /// Start a retry request and record what it returns.
    ///
    /// The return is parked in a box so a test can observe *whether* the caller
    /// came back, and with what, without awaiting it.
    private func startRetry(
        _ manager: SessionManager,
        tab: TerminalTab,
        label: String
    ) -> Finished {
        let box = NIOLockedValueBox<SessionManager.AuthRetryResult?>(nil)
        let done = NIOLockedValueBox(false)
        Task { @MainActor in
            let outcome = await manager.requestAuthRetry(for: tab, rawError: "auth failed")
            box.withLockedValue { $0 = outcome }
            done.withLockedValue { $0 = true }
        }
        return Finished(box: box, done: done, label: label)
    }

    struct Finished {
        let box: NIOLockedValueBox<SessionManager.AuthRetryResult?>
        let done: NIOLockedValueBox<Bool>
        let label: String

        var hasReturned: Bool { done.withLockedValue { $0 } }
        var password: String? { box.withLockedValue { $0 }?.password }
    }

    /// Yield enough times for parked tasks to reach their continuation.
    private func settle(_ rounds: Int = 6) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    // MARK: - The hang this exists for

    /// Two tabs failing auth must not share one slot.
    ///
    /// With a single continuation, the second request overwrote the first and
    /// the first caller is never resumed: it stays suspended forever, and the
    /// tab is stuck. Nothing in the UI reports this, so it presents as a silent
    /// hang rather than a failure.
    ///
    /// The sheet can only present one request, so tab A is unanswerable once B
    /// supersedes it. Releasing it as *cancelled* is the correct outcome — the
    /// requirement is that A returns rather than hangs, and crucially that A
    /// never receives B's password.
    @Test("A second tab's request does not orphan the first tab's waiter")
    func secondRequestDoesNotOrphanTheFirst() async {
        let manager = SessionManager()
        let tabA = makeTab("A")
        let tabB = makeTab("B")

        let first = startRetry(manager, tab: tabA, label: "A")
        await settle()
        let second = startRetry(manager, tab: tabB, label: "B")
        await settle()

        #expect(first.hasReturned,
                "the superseded request must be released, not left suspended forever")
        #expect(first.password == nil, "a superseded request resolves as cancelled")

        manager.completeAuthRetry(with: result("b-password"))
        await settle()

        #expect(second.hasReturned, "the second request must be answered")
        #expect(second.password == "b-password")
        #expect(first.password == nil, "tab A must never receive tab B's result")
    }

    /// A result must reach the tab that asked for it.
    @Test("A completion is delivered to the requesting tab")
    func completionGoesToTheRequestingTab() async {
        let manager = SessionManager()
        let tabA = makeTab("A")
        let tabB = makeTab("B")

        let first = startRetry(manager, tab: tabA, label: "A")
        await settle()
        let second = startRetry(manager, tab: tabB, label: "B")
        await settle()

        manager.completeAuthRetry(with: result("for-b"))
        await settle()

        #expect(second.password == "for-b", "tab B asked, so tab B is answered")
        #expect(first.password == nil, "tab A must not receive tab B's result")
    }
    /// Closing a tab must release its waiter.
    ///
    /// `closeTab` already clears the tab's retry state and its dialog flag. If
    /// it does not also release the waiter, the suspended caller outlives the
    /// tab it was waiting for.
    @Test("Closing a tab releases its pending waiter")
    func closingATabReleasesItsWaiter() async {
        let manager = SessionManager()
        let tab = makeTab("A")
        manager.tabs.append(tab)

        let pending = startRetry(manager, tab: tab, label: "A")
        await settle()
        #expect(!pending.hasReturned, "the request should be parked")

        await manager.closeTab(tab.id)
        await settle()

        #expect(pending.hasReturned,
                "closing the tab must release its waiter, or the caller hangs forever")
        #expect(pending.password == nil, "a closed tab resolves with no result")
    }

    /// Re-registering the same tab must not orphan the earlier waiter.
    @Test("Re-registering the same tab does not orphan the earlier waiter")
    func reRegisteringSameTabDoesNotOrphan() async {
        let manager = SessionManager()
        let tab = makeTab("A")

        let first = startRetry(manager, tab: tab, label: "A")
        await settle()
        let second = startRetry(manager, tab: tab, label: "A2")
        await settle()

        manager.completeAuthRetry(with: result("second"))
        await settle()

        #expect(second.password == "second")
        #expect(first.hasReturned,
                "the superseded request must be released, not left suspended")
    }

    // MARK: - Exactly-once

    /// A waiter resumes once.
    ///
    /// Resuming a `CheckedContinuation` twice is a runtime trap, so a bug here
    /// would crash rather than fail. `resolveCount` makes the property
    /// observable: a second completion must be a no-op.
    @Test("A waiter resumes exactly once")
    func resumesExactlyOnce() async {
        let manager = SessionManager()
        let tab = makeTab("A")
        let pending = startRetry(manager, tab: tab, label: "A")
        await settle()

        manager.completeAuthRetry(with: result("once"))
        manager.completeAuthRetry(with: result("twice"))
        manager.cancelAuthRetry()
        await settle()

        #expect(pending.password == "once",
                "the first completion wins; later ones must not re-resume or replace it")
        #expect(manager.authRetryRequest == nil, "the request is cleared once answered")
    }

    /// Answering when nothing is pending is harmless.
    @Test("Completing with nothing pending is a no-op")
    func completingWithNothingPending() async {
        let manager = SessionManager()
        manager.completeAuthRetry(with: result("stray"))
        manager.cancelAuthRetry()
        #expect(manager.authRetryRequest == nil)
    }

    // MARK: - Teardown

    /// Tearing down every session releases every parked waiter.
    ///
    /// `disconnectAllTabs` is the path taken when the app is shutting the
    /// session set down. A caller suspended on an auth-retry continuation must
    /// not outlive the sessions it was waiting on.
    @Test("Tearing down all sessions releases parked waiters")
    func teardownReleasesWaiters() async {
        let manager = SessionManager()
        let tab = makeTab("A")
        manager.tabs.append(tab)

        let pending = startRetry(manager, tab: tab, label: "A")
        await settle()
        #expect(!pending.hasReturned, "the request should be parked")
        #expect(manager.authRetryWaiters.count == 1)

        await manager.disconnectAllTabs()
        await settle()

        #expect(pending.hasReturned,
                "teardown must release parked waiters, or callers hang at shutdown")
        #expect(manager.authRetryWaiters.isEmpty, "teardown clears the waiter table")
        #expect(manager.authRetryRequest == nil, "teardown clears the visible request")
    }

    // MARK: - Why resolving by request is equivalent to resolving by waiter

    /// At most one waiter is ever live.
    ///
    /// `completeAuthRetry` looks its waiter up by the requesting tab rather than
    /// taking whichever waiter happens to be around. Those two are equivalent
    /// only because of this invariant: a new request always supersedes and
    /// releases the previous one. If a second waiter ever became live, the
    /// strategies would diverge and a password could reach the wrong tab, so
    /// the invariant is asserted rather than assumed.
    @Test("Only one auth retry waiter is ever live")
    func onlyOneWaiterIsEverLive() async {
        let manager = SessionManager()
        let tabA = makeTab("A")
        let tabB = makeTab("B")
        let tabC = makeTab("C")

        let first = startRetry(manager, tab: tabA, label: "A")
        await settle()
        #expect(manager.authRetryWaiters.count == 1)

        let second = startRetry(manager, tab: tabB, label: "B")
        await settle()
        #expect(manager.authRetryWaiters.count == 1,
                "superseding must release the previous waiter, not accumulate")
        #expect(first.hasReturned, "the superseded waiter is released immediately")

        let third = startRetry(manager, tab: tabC, label: "C")
        await settle()
        #expect(manager.authRetryWaiters.count == 1)
        #expect(second.hasReturned)

        manager.completeAuthRetry(with: result("c-password"))
        await settle()
        #expect(third.password == "c-password")
        #expect(manager.authRetryWaiters.isEmpty, "answering clears the waiter")
    }

    // MARK: - The exactly-once primitive itself

    /// `AuthRetryWaiter` resumes at most once.
    ///
    /// The integration tests above cannot isolate this: `completeAuthRetry`
    /// clears `authRetryRequest` after the first answer, so a second call
    /// returns early and the waiter is never resolved twice. That hides a
    /// regression in the waiter's own guard. Resuming a `CheckedContinuation`
    /// twice is a runtime trap, so removing the guard would crash rather than
    /// fail — which is exactly why it needs a test of its own.
    @Test("A waiter ignores every resolve after the first")
    func waiterResolvesAtMostOnce() async {
        let returns = NIOLockedValueBox<Int>(0)
        let waiterBox = NIOLockedValueBox<AuthRetryWaiter?>(nil)

        Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<SessionManager.AuthRetryResult?, Never>) in
                waiterBox.withLockedValue { $0 = AuthRetryWaiter(continuation) }
            }
            returns.withLockedValue { $0 += 1 }
        }
        await settle()
        let waiter = try? #require(waiterBox.withLockedValue { $0 })
        guard let waiter else {
            Issue.record("the waiter should have been registered")
            return
        }

        #expect(waiter.resolve(nil) == true, "the first resolve resumes")
        #expect(waiter.resolveCount == 1)
        #expect(waiter.isResolved)

        // Every later resolve is refused, and does not change the answer.
        #expect(waiter.resolve(result("late")) == false,
                "a second resolve must be refused, not attempted")
        #expect(waiter.resolveCount == 1, "resolveCount must not advance")
        #expect(waiter.resolve(nil) == false)

        await settle()
        #expect(returns.withLockedValue { $0 } == 1,
                "the suspended caller must return exactly once")
    }
}
