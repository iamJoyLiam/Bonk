//
//  ConnectionManager.swift
//  Bonk
//
//  Manages SSH connections - connect, disconnect, reconnect.
//

import Foundation

/// Manages SSH connections - connect, disconnect, reconnect.
@Observable @MainActor
final class ConnectionManager {
    private let hostKeyStore = PersistentHostKeyStore()
    private let sessionStore = SessionStore.shared

    /// Connect a tab.
    func connect(_ tab: TerminalTab) async {
        let session = sessionStore.session(for: tab)
        tab.session = session
        session.connectionState = .connecting
        session.errorMessage = nil

        // Connection logic will be moved here from SessionManager
    }

    /// Disconnect a tab.
    func disconnect(_ tab: TerminalTab) async {
        await sessionStore.disconnect(tab.id)
        tab.session?.disconnect()
        tab.session = nil
    }

    /// Reconnect a tab.
    func reconnect(_ tab: TerminalTab) async {
        await disconnect(tab)
        await connect(tab)
    }
}
