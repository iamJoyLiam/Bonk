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
        // Tier 1 — TERMINAL CONTROL: CSI/OSC/SGR must bypass decoration, VT semantics intact.
        if text.contains("\u{1B}") {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        // Tier 1b — Alternate screen (vim/less/top/fzf) is terminal control, never regex-color.
        if let terminalViewForCheck = terminalView, terminalViewForCheck.terminal.isCurrentBufferAlternate {
            terminalViewForCheck.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        // Tier 3 — BULK degrades at decoration layer (never drop bytes, only skip coloring).
        let lineCount = max(1, text.filter { $0 == "\n" }.count + 1)
        if DegradedMode.shared.shouldDropLogHighlight(lineCount: lineCount) {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        // Tier 2 — INTERACTIVE fast-path: tiny single-line echo bypasses worker queue.
        // Heuristic only affects decoration (missing color is safe), never VT correctness.
        // Covers shell echo `a`/`ls` without blocking behind 32-job backlog.
        if text.utf8.count <= 64, !text.contains("\n") {
            terminalView?.feed(text: text)
            onBytesConsumed?(text.utf8.count)
            return
        }
        let bytes = text.utf8.count
        let terminalViewForWorker = terminalView
        let onConsumedForWorker = onBytesConsumed
        let hostForWorker = host
        worker.enqueue(text: text, host: hostForWorker) { colored in
            terminalViewForWorker?.feed(text: colored)
            onConsumedForWorker?(bytes)
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
        // Alternate screen content is terminal control, not log bulk.
        // TeamRelay host view may still be in alt screen; skip coloring for it.
        let lineCountForTeam = max(1, text.filter { $0 == "\n" }.count + 1)
        if DegradedMode.shared.shouldDropLogHighlight(lineCount: lineCountForTeam) {
            TeamRelay.shared.broadcastOutput(text, sessionID: sessionID)
            return
        }
        if text.utf8.count <= 64, !text.contains("\n") {
            TeamRelay.shared.broadcastOutput(text, sessionID: sessionID)
            return
        }
        let sessionIDForWorker = sessionID
        let hostForTeamWorker = host
        worker.enqueue(text: text, host: hostForTeamWorker) { colored in
            TeamRelay.shared.broadcastOutput(colored, sessionID: sessionIDForWorker)
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
