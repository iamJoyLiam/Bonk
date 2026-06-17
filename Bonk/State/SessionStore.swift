//
//  SessionStore.swift
//  Bonk
//
//  Manages session lifecycle and prevents duplicate connections.
//  Centralizes session creation, retrieval, and cleanup.
//

import Foundation

/// Manages session lifecycle and prevents duplicate connections.
@Observable @MainActor
final class SessionStore {
    static let shared = SessionStore()

    // MARK: - State

    private var activeSessions: [UUID: TerminalSession] = [:]
    private var connectingSessions: Set<UUID> = []

    private init() {}

    // MARK: - Public API

    /// Get or create a session for a tab.
    func session(for tab: TerminalTab) -> TerminalSession {
        if let existing = activeSessions[tab.id] {
            return existing
        }
        let session = TerminalSession(tabID: tab.id)
        activeSessions[tab.id] = session
        return session
    }

    /// Get an existing session for a tab (returns nil if none exists).
    func existingSession(for tabID: UUID) -> TerminalSession? {
        activeSessions[tabID]
    }

    /// Check if a session is connecting.
    func isConnecting(_ tabID: UUID) -> Bool {
        connectingSessions.contains(tabID)
    }

    /// Mark a session as connecting.
    func markConnecting(_ tabID: UUID) {
        connectingSessions.insert(tabID)
    }

    /// Mark a session as connected.
    func markConnected(_ tabID: UUID) {
        connectingSessions.remove(tabID)
    }

    /// Remove a session.
    func removeSession(_ tabID: UUID) {
        activeSessions.removeValue(forKey: tabID)
        connectingSessions.remove(tabID)
    }

    /// Disconnect a session.
    func disconnect(_ tabID: UUID) async {
        guard let session = activeSessions[tabID] else { return }
        await session.sshService?.disconnect()
        session.disconnect()
    }

    /// Get all active session IDs.
    var activeSessionIDs: [UUID] {
        Array(activeSessions.keys)
    }

    /// Check if a session exists.
    func hasSession(for tabID: UUID) -> Bool {
        activeSessions[tabID] != nil
    }
}
