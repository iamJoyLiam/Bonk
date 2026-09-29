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
import Network

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

    func send(_ bytes: [UInt8], completion: @escaping (Error?) -> Void)
    func receive(maxBytes: Int, completion: @escaping (Data?, Bool, Error?) -> Void)
    func cancel()
}

/// Bridges `NWConnection` to `TeamChannel`.
///
/// This is the plaintext implementation. It exists so the transport
/// abstraction can be introduced without changing behaviour, and so the
/// plaintext path can be deleted in one place once SSH is the only path.
extension NWConnection: TeamChannel {
    var onStateChange: (@Sendable (TeamChannelState) -> Void)? {
        get { nil }
        set {
            guard let newValue else { return }
            stateUpdateHandler = { state in
                switch state {
                case .ready: newValue(.ready)
                case let .failed(error): newValue(.failed(error.localizedDescription))
                case .cancelled: newValue(.cancelled)
                default: break
                }
            }
        }
    }

    func activate() { start(queue: .global(qos: .utility)) }

    func send(_ bytes: [UInt8], completion: @escaping (Error?) -> Void) {
        send(content: Data(bytes), completion: .contentProcessed(completion))
    }

    func receive(maxBytes: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }
}
