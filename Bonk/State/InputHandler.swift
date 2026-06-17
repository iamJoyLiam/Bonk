//
//  InputHandler.swift
//  Bonk
//
//  Handles terminal input processing, command history recording, and broadcast.
//

import Foundation

/// Processes terminal input with command history recording and broadcast support.
@Observable @MainActor
final class InputHandler {
    /// Send input bytes to a terminal tab, recording command history and broadcasting if enabled.
    func sendInput(
        _ bytes: ArraySlice<UInt8>,
        to tab: TerminalTab,
        broadcastManager: BroadcastManager?,
        allTabs: [TerminalTab]
    ) async throws {
        // 1. Record command history
        recordCommandIfNeeded(bytes, to: tab)

        // 2. Send to PTY
        guard let pty = tab.session?.ptySession else { return }
        try await pty.sendInput(bytes)

        // 3. Broadcast to other target panes
        if let broadcast = broadcastManager, broadcast.isEnabled {
            for targetID in broadcast.targetPaneIDs {
                guard targetID != tab.id,
                      let targetTab = allTabs.first(where: { $0.id == targetID }),
                      let targetPTY = targetTab.session?.ptySession else { continue }
                try? await targetPTY.sendInput(bytes)
            }
        }
    }

    /// Convenience: send text string to a tab (auto-appends Enter).
    func sendText(_ text: String, to tab: TerminalTab, broadcastManager: BroadcastManager? = nil, allTabs: [TerminalTab] = []) async throws {
        let bytes = Array(text.utf8 + [13])
        try await sendInput(bytes[...], to: tab, broadcastManager: broadcastManager, allTabs: allTabs)
    }

    // MARK: - Private

    private func recordCommandIfNeeded(_ bytes: ArraySlice<UInt8>, to tab: TerminalTab) {
        if bytes == [13] {
            // Enter pressed — record accumulated input buffer
            if let inputBuffer = tab.session?.inputBuffer, !inputBuffer.isEmpty {
                let trimmed = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tab.session?.commandHistory.commandStarted(trimmed)
                    tab.session?.commandHistory.commandFinished(exitCode: 0)
                }
                tab.session?.inputBuffer = ""
            }
        } else {
            // Accumulate typed characters (exclude control chars except backspace)
            for byte in bytes {
                if byte == 127 || byte == 8 {
                    // Backspace/Delete — remove last char
                    tab.session?.inputBuffer = String(tab.session?.inputBuffer.dropLast() ?? "")
                } else if byte >= 32 {
                    // Printable character
                    tab.session?.inputBuffer = (tab.session?.inputBuffer ?? "") + String(UnicodeScalar(byte))
                }
            }
        }
    }
}
