//
//  TerminalEngineAdapter.swift
//  Bonk
//
//  Adapters behind TerminalConsumer seam.
//

import Foundation

#if os(macOS)
import AppKit
import SwiftTerm

/// Adapter for real SwiftTerm view. Keeps AppKit out of Engine.
@MainActor
final class AppKitTerminalConsumer: TerminalConsumer {
    weak var terminalView: SwiftTerm.TerminalView?
    private var onBytesConsumed: (@Sendable (Int) -> Void)?

    init(terminalView: SwiftTerm.TerminalView, onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
        self.terminalView = terminalView
        self.onBytesConsumed = onBytesProcessed
    }

    func receive(_ text: String) {
        terminalView?.feed(text: text)
    }

    func didConsume(bytes: Int) { onBytesConsumed?(bytes) }
}
#endif

/// Team adapter — same coalesced text as local view, broadcast to guests.
@MainActor
final class TeamTerminalConsumer: TerminalConsumer {
    let sessionID: TeamSessionID
    init(sessionID: TeamSessionID) { self.sessionID = sessionID }
    func receive(_ text: String) {
        TeamRelay.shared.broadcastOutput(text, sessionID: sessionID)
    }
}

/// Headless adapter for tests — records receives without SwiftTerm/AppKit.
@MainActor
final class HeadlessTerminalConsumer: TerminalConsumer {
    private(set) var received: [String] = []
    private(set) var totalBytes: Int = 0
    var onReceive: ((String) -> Void)?

    func receive(_ text: String) {
        received.append(text)
        totalBytes += text.utf8.count
        onReceive?(text)
    }

    func didConsume(bytes: Int) { totalBytes += 0 } // already counted

    var joined: String { received.joined() }
    func clear() { received.removeAll(); totalBytes = 0 }
}
