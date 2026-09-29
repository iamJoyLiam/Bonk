//
//  TeamPINAuthenticator.swift
//  Bonk
//
//  SSH user authentication for the team relay: the 6-digit team PIN is the
//  credential, and it is consumed *here only* — the Team protocol keeps
//  carrying the PIN until this transport is the production path, at which
//  point the duplication goes away in the same commit that removes the
//  plaintext listener.
//
//  This is the layer that makes "6 digits" a control. The relay's port is
//  advertised over Bonjour, so any host on the LAN can reach it and start
//  guessing; without a bound, the PIN is not a credential. The decision is a
//  pure function of (peer, pin, attempt timestamps, now) so both the allow and
//  the deny paths are testable without a socket.
//

import Foundation
import NIOConcurrencyHelpers

/// Verifies the team PIN and bounds how often it may be guessed.
///
/// ## Why the global budget is the load-bearing control
///
/// SSH user authentication hands the delegate a *client-supplied* username and
/// no peer address, so a per-peer failure budget keyed on the username is
/// trivially bypassed: an attacker simply sends a different username per
/// attempt. The per-peer budget is therefore only a courtesy to honest clients
/// and a debugging aid.
///
/// The control that actually bounds guessing is the **global** budget below:
/// no input a client can choose influences it, so the number of PIN comparisons
/// per time window is capped no matter how the attacker varies its requests.
/// Without it, a 6-digit PIN advertised over Bonjour is brute-forceable.
struct TeamPINAuthenticator: Sendable {
    struct Limits: Sendable, Equatable {
        /// Failures allowed per window before the peer is refused.
        var maxFailuresPerWindow: Int = 5
        /// Window over which failures are counted.
        var window: TimeInterval = 60
        /// After the budget is spent, refuse for at least this long.
        var lockout: TimeInterval = 30
        /// Failures allowed across *all* peers per window. This is the budget
        /// that survives a client choosing a fresh username each attempt.
        var maxGlobalFailuresPerWindow: Int = 20

        static let `default` = Limits()
    }

    enum Decision: Equatable {
        case accept
        /// Wrong PIN. `remaining` tells the caller how many guesses are left.
        case reject(remaining: Int)
        /// A failure budget is spent; refuse without comparing.
        case lockedOut(retryAfter: TimeInterval)
    }

    private let state = NIOLockedValueBox<[String: PeerState]>([:])
    private let globalState = NIOLockedValueBox<GlobalState>(GlobalState())
    private let limits: Limits

    init(limits: Limits = .default) {
        self.limits = limits
    }

    private struct PeerState {
        var failures: [Date]
        var lockedUntil: Date?
    }

    private struct GlobalState {
        var failures: [Date] = []
        var lockedUntil: Date?
    }

    /// Decide whether `presentedPin` may open a session with `peer`.
    ///
    /// Ordering matters and is the point of the type: **the lockout is checked
    /// before the comparison**, so a locked-out peer is refused even if it
    /// presents the correct PIN. Comparing first would confirm a guess for free
    /// — a peer that had already exhausted its budget would learn the PIN from
    /// the difference between "wrong" and "locked out".
    func evaluate(peer: String, presentedPin: String, expectedPin: String, now: Date = Date()) -> Decision {
        let key = peer.isEmpty ? "unknown" : peer

        var outcome: Decision = .accept
        state.withLockedValue { peers in
            var entry = peers[key] ?? PeerState(failures: [], lockedUntil: nil)

            // 1. This peer's own budget.
            if let lockedUntil = entry.lockedUntil, lockedUntil > now {
                outcome = .lockedOut(retryAfter: lockedUntil.timeIntervalSince(now))
                peers[key] = entry
                return
            }
            if entry.lockedUntil != nil { entry.lockedUntil = nil }

            // 2. The global budget — checked before the comparison too, so
            //    exhausting it never leaks whether a presented PIN was right.
            let global = globalState.withLockedValue { global -> Decision in
                if let lockedUntil = global.lockedUntil, lockedUntil > now {
                    return .lockedOut(retryAfter: lockedUntil.timeIntervalSince(now))
                }
                if global.lockedUntil != nil { global.lockedUntil = nil }
                global.failures.removeAll { $0 < now.addingTimeInterval(-limits.window) }
                return .accept
            }
            if case let .lockedOut(retryAfter) = global {
                peers[key] = entry
                outcome = .lockedOut(retryAfter: retryAfter)
                return
            }

            // 3. Only now is the PIN compared.
            if Self.constantTimeEquals(presentedPin, expectedPin) {
                entry.failures = []
                entry.lockedUntil = nil
                outcome = .accept
            } else {
                let lockedOut = recordGlobalFailure(now: now)
                entry.failures.append(now)
                let cutoff = now.addingTimeInterval(-limits.window)
                entry.failures.removeAll { $0 < cutoff }
                let remaining = max(0, limits.maxFailuresPerWindow - entry.failures.count)
                if remaining == 0 {
                    entry.lockedUntil = now.addingTimeInterval(limits.lockout)
                }
                outcome = lockedOut ?? .reject(remaining: remaining)
            }
            peers[key] = entry

            // Opportunistic cleanup so a busy LAN cannot grow the table
            // without bound.
            let stale = now.addingTimeInterval(-limits.window * 2)
            for (peerKey, peerEntry) in peers
            where peerEntry.failures.allSatisfy({ $0 < stale })
                && (peerEntry.lockedUntil ?? stale) <= now {
                peers[peerKey] = nil
            }
        }
        return outcome
    }

    /// Count a failure against the global budget.
    ///
    /// - Returns: `.lockedOut` when the budget is now spent, so the caller can
    ///   report a lockout instead of a "wrong PIN, 0 remaining" that would
    ///   still tell the attacker the budget is exactly exhausted.
    private func recordGlobalFailure(now: Date) -> Decision? {
        globalState.withLockedValue { global in
            global.failures.append(now)
            let cutoff = now.addingTimeInterval(-limits.window)
            global.failures.removeAll { $0 < cutoff }
            guard global.failures.count >= limits.maxGlobalFailuresPerWindow else { return nil }
            global.lockedUntil = now.addingTimeInterval(limits.lockout)
            return .lockedOut(retryAfter: limits.lockout)
        }
    }

    /// Constant-time comparison: no early exit on the first mismatch, so a
    /// six-digit PIN does not leak how many leading digits were right.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        // Length is not secret (the PIN's length is fixed and public).
        var difference = UInt8(lhs.count ^ rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }

    /// Forget a peer's history — called once a session is established, so a
    /// peer that failed twice and then succeeded starts clean.
    func reset(peer: String) {
        state.withLockedValue { $0[peer.isEmpty ? "unknown" : peer] = nil }
    }
}
