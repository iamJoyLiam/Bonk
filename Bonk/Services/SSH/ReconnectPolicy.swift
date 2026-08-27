//
//  ReconnectPolicy.swift
//  Bonk
//
//  Single backoff implementation for SSH reconnect (Phase 3).
//  Extracted from SSHNetworkService's duplicated reconnect/reconnectOpenSSH.
//

import Foundation

/// Exponential backoff with jitter, single source of truth for SSH reconnect.
struct ReconnectPolicy: Sendable {
    let baseDelay: Duration
    let maxDelay: Duration
    let maxAttempts: Int
    let jitter: ClosedRange<Double>

    static let `default` = ReconnectPolicy(
        baseDelay: .milliseconds(500),
        maxDelay: .seconds(30),
        maxAttempts: 5,
        jitter: 0.8...1.2
    )

    func delay(for attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }
        let jitterFactor = Double.random(in: jitter)
        let exp = min(Double(1 << min(attempt, 10)) * baseDelay.timeInterval * jitterFactor, maxDelay.timeInterval)
        return .milliseconds(Int(exp * 1000))
    }
}

private extension Duration {
    var timeInterval: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}
