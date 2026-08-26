import Foundation

// MARK: - Host broadcast API (called by PTY)

extension TeamRelay {
    func broadcastOutput(_ chunk: String, sessionID: TeamSessionID? = nil) {
        guard isHostMode, !chunk.isEmpty, let sessionID else { return }

        if sharedSessionID == nil {
            sharedSessionID = sessionID
            updatePresenceSnapshot()
        }
        guard sharedSessionID == sessionID else { return }

        appendReplay(sessionID: sessionID, payload: chunk)
        broadcastToGuests(.terminalOutput(sessionID: sessionID, payload: chunk))
    }

    func setSharedSession(tabID: UUID, paneID: UUID) {
        guard isHosting else { return }
        let sessionID = TeamSessionID(tabID: tabID, paneID: paneID)
        guard sharedSessionID != sessionID else { return }
        sharedSessionID = sessionID
        replayBuffer.removeAll()
        replayByteCount = 0
        updatePresenceSnapshot()
    }

    func clearSharedSession() {
        guard isHosting else { return }
        sharedSessionID = nil
        replayBuffer.removeAll()
        replayByteCount = 0
        updatePresenceSnapshot()
    }

    func broadcastResize(columns: Int, rows: Int, sessionID: TeamSessionID) {
        guard isHostMode, sharedSessionID == sessionID else { return }
        broadcastToGuests(.resize(sessionID: sessionID, columns: columns, rows: rows))
    }
}

// MARK: - Presence / Replay

extension TeamRelay {
    func updatePresenceSnapshot() {
        guard let hostPeer else { return }
        let snapshot = TeamPresenceSnapshot(
            hostPeer: hostPeer,
            guestPeers: connectedPeers,
            driverPeerID: driverPeerID,
            sharedSessionID: sharedSessionID
        )
        broadcastToGuests(.presenceSnapshot(snapshot: snapshot))
    }

    func appendReplay(sessionID: TeamSessionID, payload: String) {
        replayBuffer.append(ReplayChunk(sessionID: sessionID, payload: payload))
        replayByteCount += payload.utf8.count
        while replayByteCount > TeamConstants.replayBufferByteLimit ||
              replayBuffer.count > TeamConstants.replayBufferLineLimit
        {
            guard let removed = replayBuffer.first else { break }
            replayByteCount -= removed.payload.utf8.count
            replayBuffer.removeFirst()
        }
    }

    func sendReplay(to peerConnectionID: UUID) {
        guard let connection = hostedConnections[peerConnectionID] else { return }
        for chunk in replayBuffer {
            sendMessage(
                .terminalOutput(sessionID: chunk.sessionID, payload: chunk.payload),
                to: connection
            )
        }
    }
}
