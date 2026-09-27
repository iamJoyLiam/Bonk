//
//  SessionManager+Input.swift
//  Bonk
//
//  Terminal input, broadcast, and Zmodem entry points extracted from
//  SessionManager to keep the class body within size limits.
//

import os.log
import SwiftData
import SwiftTerm
import SwiftUI

// MARK: - SessionManager Input

extension SessionManager {
    func resizePTY(cols: Int, rows: Int, tabID: UUID, paneID: UUID? = nil) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let targetPaneID = paneID ?? tab.activePaneID else { return }
        guard let pane = tab.layout.findPane(id: targetPaneID),
              let pty = pane.ptySession else { return }
        try await pty.resize(cols: cols, rows: rows)
    }

    func updateTabTitle(_ title: String, tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if let cwd = parseCWD(from: title, username: tab.hostItem.username) {
            tab.currentDirectory = cwd
        }
    }

    func parseCWD(from title: String, username: String) -> String? {
        // Pattern: "user@host:/absolute/path" or "user@host:~/path"
        if let colonRange = title.range(of: ": ") {
            let afterColon = String(title[colonRange.upperBound...])
            let path = afterColon.components(separatedBy: " ").first ?? afterColon
            if path.hasPrefix("/") { return path }
            // Handle ~ paths — expand to the actual user's home directory
            if path.hasPrefix("~") {
                let home = "/home/\(username)"
                let relativePath = path.dropFirst()
                if relativePath.isEmpty { return home }
                if relativePath.hasPrefix("/") {
                    return home + String(relativePath)
                }
                return home + "/" + String(relativePath)
            }
        }
        // Pattern: "/absolute/path" as title
        if title.hasPrefix("/") {
            return title.components(separatedBy: " ").first ?? title
        }
        return nil
    }

    func sendInput(_ bytes: ArraySlice<UInt8>, to tabID: UUID, paneID: UUID? = nil) async throws {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let targetPaneID = paneID ?? tab.activePaneID else { return }
        // Only block input during authenticating to avoid command typed as password
        // waitingPTY/openingChannel/openingPTY should allow input (fixes terminal freeze after 2.7)
        if let sessionState = tab.session, sessionState.phase == .authenticating {
            return
        }

        // Use inputHandler to record command history and broadcast
        try await inputHandler.sendInput(
            bytes,
            to: tab,
            paneID: targetPaneID,
            broadcastManager: broadcastManager,
            allTabs: tabs
        )
    }

    // MARK: - Zmodem

    /// Start Zmodem file send.
    func startZmodemSend(tabID: UUID, paneID: UUID, files: [URL]) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let pane = tab.layout.findPane(id: paneID),
              let pty = pane.ptySession else { return }

        if pty.zmodemHandler == nil {
            pty.setupZmodem()
        }
        pty.startZmodemSend(files: files)
    }

    /// Start Zmodem file receive.
    func startZmodemReceive(tabID: UUID, paneID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let pane = tab.layout.findPane(id: paneID),
              let pty = pane.ptySession else { return }

        if pty.zmodemHandler == nil {
            pty.setupZmodem()
        }
        pty.startZmodemReceive()
    }

    /// Convenience: send text to the active pane (auto-appends Enter).
    func sendTextToActiveTab(_ text: String) {
        guard let tab = activeTab, let paneID = tab.activePaneID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            let cmdBytes = Array(trimmed.utf8)[...]
            try? await sendInput(cmdBytes, to: tab.id, paneID: paneID)
            try? await Task.sleep(for: .milliseconds(15))
            let enterBytes: ArraySlice<UInt8> = [13]
            try? await sendInput(enterBytes, to: tab.id, paneID: paneID)
        }
    }

    /// Toggle local broadcast for a tab.
    func toggleTabBroadcast(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.isBroadcastEnabled.toggle()
    }

    /// Clean up input handler resources when a tab is closed.
    /// Called from closeTab to prevent utf8Parsers dictionary growth.
    func cleanupInputHandler(for tabID: UUID) {
        inputHandler.utf8Parsers[tabID] = nil
    }

    // MARK: - Broadcast Sync

    func syncBroadcastTargets() {
        let allPaneIDs = tabs.flatMap(\.paneIDs)
        broadcastManager?.allPaneIDs = allPaneIDs
        let validIDs = Set(allPaneIDs)
        broadcastManager?.targetPaneIDs = broadcastManager?.targetPaneIDs.filter { validIDs.contains($0) } ?? []
    }
}
