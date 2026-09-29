//
//  TeamTransport.swift
//  Bonk
//
//  The minimum channel surface the team relay needs, so the transport can be
//  swapped without touching application logic.
//
//  The relay only ever does three things with a peer connection: send framed
//  bytes, receive framed bytes, and close. Expressing exactly that keeps the
//  abstraction honest — and, more usefully, means there is no way to reach
//  for a raw `NWConnection` and accidentally reintroduce a plaintext path.
//
//  The lifecycle callback is modelled explicitly rather than exposing a
//  `Network.NWConnection` state type, for the same reason: a transport has no
//  business knowing what `NWConnection.State` is.
//

import Foundation

/// Lifecycle of a team channel, modelled explicitly so a transport never has
/// to know what `NWConnection.State` is.
enum TeamChannelState: Sendable {
    case ready
    case failed(String)
    case cancelled
}

/// A bidirectional byte channel to one peer.
protocol TeamChannel: AnyObject {
    /// Observe lifecycle changes. Equivalent to `NWConnection.stateUpdateHandler`.
    var onStateChange: (@Sendable (TeamChannelState) -> Void)? { get set }

    /// Begin transferring on this channel. A transport that hands out
    /// already-live channels implements this as a no-op.
    func activate()

    /// Completions are `@Sendable` because a transport may fulfil them on
    /// an event loop rather than the caller's context.
    func send(_ bytes: [UInt8], completion: @escaping @Sendable (Error?) -> Void)
    func receive(maxBytes: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void)
    func cancel()
}

/// There is deliberately **no** `NWConnection` conformance here.
///
/// When SSH became the only transport, a plaintext `NWConnection` could still
/// satisfy `TeamChannel`, which would leave "the team relay speaks only over
/// SSH" as a convention rather than a property of the type. Removing the
/// conformance makes reintroducing a plaintext path require writing a
/// conformance by hand — an explicit, reviewable act.
