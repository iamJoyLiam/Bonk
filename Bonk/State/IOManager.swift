//
//  IOManager.swift
//  Bonk
//
//  Manages terminal input/output operations.
//

import Foundation

/// Manages terminal input/output operations.
@Observable @MainActor
final class IOManager {
    /// Handles input processing, command history, and broadcast.
    let inputHandler = InputHandler()

    /// Send input bytes to a tab.
    func sendInput(_ bytes: ArraySlice<UInt8>, to tab: TerminalTab, broadcastManager: BroadcastManager? = nil, allTabs: [TerminalTab] = []) async throws {
        try await inputHandler.sendInput(bytes, to: tab, broadcastManager: broadcastManager, allTabs: allTabs)
    }

    /// Send text to a tab (auto-appends Enter).
    func sendText(_ text: String, to tab: TerminalTab, broadcastManager: BroadcastManager? = nil, allTabs: [TerminalTab] = []) async throws {
        try await inputHandler.sendText(text, to: tab, broadcastManager: broadcastManager, allTabs: allTabs)
    }

    /// Resize PTY for a tab.
    func resizePTY(cols: Int, rows: Int, tab: TerminalTab) async throws {
        guard let service = tab.session?.sshService else { return }
        try await service.resizePTY(cols: cols, rows: rows)
    }
}
