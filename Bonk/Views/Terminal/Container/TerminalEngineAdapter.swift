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
/// Ultimate: off MainActor heavy regex → utility queue 16ms batch, never blocks renderer.
@MainActor
final class AppKitTerminalConsumer: TerminalConsumer {
    weak var terminalView: SwiftTerm.TerminalView?
    private var onBytesConsumed: (@Sendable (Int) -> Void)?
    private let worker = LogHighlightWorker.shared

    init(terminalView: SwiftTerm.TerminalView, onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
        self.terminalView = terminalView
        self.onBytesConsumed = onBytesProcessed
    }

    func receive(_ text: String) {
        guard LogColorizerConfig.isEnabled else {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        // Fast-path: ANSI already present (e.g. ls --color) — bypass highlight
        if text.contains("\u{1B}") {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        // High-flood: degraded mode protects renderer (50k lines/sec)
        let lineCount = max(1, text.filter { $0 == "\n" }.count + 1)
        if DegradedMode.shared.shouldDropLogHighlight(lineCount: lineCount) {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        // Background: byte-scanner + token regex on utility queue (never MainActor)
        // 16ms coalesce ≈ 60 FPS terminal tick, matches Engine's displayLink
        let bytes = text.utf8.count
        let view = terminalView
        let onConsumed = onBytesConsumed
        worker.enqueue(text: text) { colored in
            // Ensure ordering: view may have been recycled (tab switch)
            view?.feed(text: colored)
            onConsumed?(bytes)
        }
    }

    func didConsume(bytes: Int) { onBytesConsumed?(bytes) }
}
#endif

/// Team adapter — same coalesced text as local view, broadcast to guests.
/// Off MainActor like local path: avoid blocking Engine tick.
@MainActor
final class TeamTerminalConsumer: TerminalConsumer {
    let sessionID: TeamSessionID
    private let worker = LogHighlightWorker.shared
    init(sessionID: TeamSessionID) { self.sessionID = sessionID }
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
        worker.enqueue(text: text) { colored in
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

    func didConsume(bytes: Int) { totalBytes += 0 } // already counted

    var joined: String { received.joined() }
    func clear() { received.removeAll(); totalBytes = 0 }
}
