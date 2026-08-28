//
//  TerminalEngineAdapter.swift
//  Bonk
//

import Foundation

#if os(macOS)
import AppKit
import SwiftTerm

/// Adapter for real SwiftTerm view.
@MainActor
final class AppKitTerminalConsumer: TerminalConsumer {
    weak var terminalView: SwiftTerm.TerminalView?
    private var onBytesConsumed: (@Sendable (Int) -> Void)?
    private let worker = LogHighlightWorker.shared
    private let host: HostItem?

    init(terminalView: SwiftTerm.TerminalView, host: HostItem? = nil, onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
        self.terminalView = terminalView
        self.host = host
        self.onBytesConsumed = onBytesProcessed
    }

    func receive(_ text: String) {
        guard LogColorizerConfig.isEnabled else {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        if text.contains("\u{1B}") {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        let lineCount = max(1, text.filter { $0 == "\n" }.count + 1)
        if DegradedMode.shared.shouldDropLogHighlight(lineCount: lineCount) {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        let bytes = text.utf8.count
        let view = terminalView
        let onConsumed = onBytesConsumed
        let h = host
        worker.enqueue(text: text, host: h) { colored in
            view?.feed(text: colored)
            onConsumed?(bytes)
        }
    }

    func didConsume(bytes: Int) { onBytesConsumed?(bytes) }
}
#endif

/// Team adapter — same coalesced text as local view, broadcast to guests.
@MainActor
final class TeamTerminalConsumer: TerminalConsumer {
    let sessionID: TeamSessionID
    private let worker = LogHighlightWorker.shared
    private let host: HostItem?
    init(sessionID: TeamSessionID, host: HostItem? = nil) { self.sessionID = sessionID; self.host = host }
    func receive(_ text: String) {
        guard LogColorizerConfig.isEnabled else {
            TeamRelay.shared.broadcastOutput(text, sessionID: sessionID)
            return
        }
        if text.contains("\u{1B}") {
            TeamRelay.shared.broadcastOutput(text, sessionID: sessionID)
            return
        }
        let lines = max(1, text.filter { $0 == "\n" }.count + 1)
        if DegradedMode.shared.shouldDropLogHighlight(lineCount: lines) {
            TeamRelay.shared.broadcastOutput(text, sessionID: sessionID)
            return
        }
        let sid = sessionID
        let h = host
        worker.enqueue(text: text, host: h) { colored in
            TeamRelay.shared.broadcastOutput(colored, sessionID: sid)
        }
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

    func didConsume(bytes: Int) { totalBytes += 0 }

    var joined: String { received.joined() }
    func clear() { received.removeAll(); totalBytes = 0 }
}
