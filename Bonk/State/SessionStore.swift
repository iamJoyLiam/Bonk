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

    /// Check if a session is connecting.
    func isConnecting(_ tabID: UUID) -> Bool {
        connectingSessions.contains(tabID)
    }

    /// Mark a session as connecting.
    func markConnecting(_ tabID: UUID) {
        connectingSessions.insert(tabID)
    }

    /// Mark a session as finished connecting.
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
        // Only disconnect SSH service if this session owns it (not shared via unsplit)
        if session.ownsSSHService {
            await session.sshService?.disconnect()
        }
        session.disconnect()
    }
}
