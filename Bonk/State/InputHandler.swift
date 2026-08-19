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
    /// Incremental UTF-8 decoders per tab, so multi-byte characters
    /// spanning multiple input chunks are assembled correctly.
    private var utf8Parsers: [UUID: UTF8Accumulator] = [:]

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

    // MARK: - Private

    private func recordCommandIfNeeded(_ bytes: ArraySlice<UInt8>, to tab: TerminalTab) {
        if bytes == [13] {
            // Enter pressed — record accumulated input buffer
            if let inputBuffer = tab.session?.inputBuffer, !inputBuffer.isEmpty {
                let trimmed = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let hostKey = tab.hostItem.id.uuidString
                    // Record to global history with host scope.
                    GlobalCommandHistory.shared.commandStarted(
                        trimmed, hostKey: hostKey
                    )
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
            // Any partial multi-byte sequence is now invalidated
            utf8Parsers[tab.id] = nil
            i = bytes.index(after: i)
        } else if byte >= 32 {
            // Printable character — decode incrementally to keep UTF-8 sequences intact
            var parser = utf8Parsers[tab.id] ?? UTF8Accumulator()
            let (scalar, isComplete) = parser.feed(byte)
            utf8Parsers[tab.id] = parser
            if isComplete, let scalar {
                tab.session?.inputBuffer = (tab.session?.inputBuffer ?? "") + String(scalar)
            }
            i = bytes.index(after: i)
                } else {
                    // Other control characters — skip
                    i = bytes.index(after: i)
                }
            }
        }
    }
}

/// Buffers a UTF-8 byte stream and emits complete scalar values once the
/// full multi-byte sequence has arrived. Invalid sequences are dropped.
private struct UTF8Accumulator {
    private var pending: [UInt8] = []

    /// Feed one byte. Returns the decoded scalar and whether the feed
    /// produced a terminal result (valid scalar or invalid sequence).
    mutating func feed(_ byte: UInt8) -> (scalar: UnicodeScalar?, isComplete: Bool) {
        pending.append(byte)

        // Try decoding the whole buffer; success means a complete sequence.
        if let scalar = decodeComplete() {
            pending = []
            return (scalar, true)
        }

        // Still a valid prefix of a longer sequence — wait for more bytes.
        if pending.count < 4 && isPartialPrefix {
            return (nil, false)
        }

        // Invalid sequence — drop it.
        pending = []
        return (nil, true)
    }

    private var isPartialPrefix: Bool {
        guard let first = pending.first else { return false }
        let expected: Int
        switch first {
        case 0xC2 ... 0xDF: expected = 2
        case 0xE0 ... 0xEF: expected = 3
        case 0xF0 ... 0xF4: expected = 4
        default: return false
        }
        return pending.dropFirst().allSatisfy { $0 & 0xC0 == 0x80 }
    }

    private func decodeComplete() -> UnicodeScalar? {
        guard let first = pending.first else { return nil }
        let count: Int
        switch first {
        case 0x00 ... 0x7F: count = 1
        case 0xC2 ... 0xDF: count = 2
        case 0xE0 ... 0xEF: count = 3
        case 0xF0 ... 0xF4: count = 4
        default: return nil
        }
        guard pending.count == count else { return nil }
        return String(bytes: pending, encoding: .utf8)?.unicodeScalars.first
    }
}
