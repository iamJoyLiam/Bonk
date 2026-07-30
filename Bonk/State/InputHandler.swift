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
    /// Send input bytes to a terminal pane, recording command history and broadcasting if enabled.
    func sendInput(
        _ bytes: ArraySlice<UInt8>,
        to tab: TerminalTab,
        paneID: UUID? = nil,
        broadcastManager: BroadcastManager?,
        allTabs: [TerminalTab]
    ) async throws {
        guard let targetPaneID = paneID ?? tab.activePaneID else { return }

        // 1. Record command history
        recordCommandIfNeeded(bytes, to: tab)

        // 2. Send to the target pane's PTY
        guard let pane = tab.layout.findPane(id: targetPaneID),
              let pty = pane.ptySession else { return }
        try await pty.sendInput(bytes)

        // 3. Broadcast to other target panes
        if let broadcast = broadcastManager, broadcast.isEnabled {
            for broadcastTargetID in broadcast.targetPaneIDs {
                // Skip the pane we already sent to
                guard broadcastTargetID != targetPaneID else { continue }

                // Find the pane in any tab
                for targetTab in allTabs {
                    if let targetPane = targetTab.layout.findPane(id: broadcastTargetID),
                       let targetPTY = targetPane.ptySession
                    {
                        try? await targetPTY.sendInput(bytes)
                        break
                    }
                }
            }
        }
    }

    /// Convenience: send text string to a pane (auto-appends Enter).
    func sendText(
        _ text: String,
        to tab: TerminalTab,
        paneID: UUID? = nil,
        broadcastManager: BroadcastManager? = nil,
        allTabs: [TerminalTab] = []
    ) async throws {
        let bytes = Array(text.utf8 + [13])
        try await sendInput(bytes[...], to: tab, paneID: paneID, broadcastManager: broadcastManager, allTabs: allTabs)
    }

    // MARK: - Private

    private func recordCommandIfNeeded(_ bytes: ArraySlice<UInt8>, to tab: TerminalTab) {
        if bytes == [13] {
            // Enter pressed — record accumulated input buffer
            if let inputBuffer = tab.session?.inputBuffer, !inputBuffer.isEmpty {
                let trimmed = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Record to global history (shared across all tabs)
                    GlobalCommandHistory.shared.commandStarted(trimmed)
                    GlobalCommandHistory.shared.commandFinished(exitCode: 0)
                    // Also record to per-session history for backward compatibility
                    tab.session?.commandHistory.commandStarted(trimmed)
                    tab.session?.commandHistory.commandFinished(exitCode: 0)
                }
                tab.session?.inputBuffer = ""
            }
        } else {
            // Accumulate typed characters (filter escape sequences)
            var i = bytes.startIndex
            while i < bytes.endIndex {
                let byte = bytes[i]
                if byte == 27 {
                    // ESC — skip entire escape sequence (e.g., \x1b[A for arrow keys)
                    // Skip ESC byte
                    i = bytes.index(after: i)
                    // Skip following bytes until we find a letter (final byte of CSI sequence)
                    while i < bytes.endIndex {
                        let next = bytes[i]
                        i = bytes.index(after: i)
                        // If it's a letter (A-Z, a-z), it's the final byte of the sequence
                        if (next >= 65 && next <= 90) || (next >= 97 && next <= 122) {
                            break
                        }
                    }
                } else if byte == 127 || byte == 8 {
                    // Backspace/Delete — remove last char
                    tab.session?.inputBuffer = String(tab.session?.inputBuffer.dropLast() ?? "")
                    i = bytes.index(after: i)
                } else if byte >= 32 {
                    // Printable character
                    tab.session?.inputBuffer = (tab.session?.inputBuffer ?? "") + String(UnicodeScalar(byte))
                    i = bytes.index(after: i)
                } else {
                    // Other control characters — skip
                    i = bytes.index(after: i)
                }
            }
        }
    }
}
