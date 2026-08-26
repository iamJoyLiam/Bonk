import Foundation

// MARK: - Control (Host)

extension TeamRelay {
    func grantControl(to peerID: UUID) {
        guard isHosting, connectedPeers.contains(where: { $0.id == peerID }) else { return }
        pendingControlRequest = nil
        driverPeerID = peerID
        for index in connectedPeers.indices {
            connectedPeers[index].isDriver = connectedPeers[index].id == peerID
        }
        if var hostPeer {
            hostPeer.isDriver = false
            self.hostPeer = hostPeer
        }
        broadcastToGuests(.controlGrant(peerID: peerID))
        updatePresenceSnapshot()
    }

    func revokeControl(from peerID: UUID) {
        guard isHosting else { return }
        if pendingControlRequest?.peerID == peerID {
            pendingControlRequest = nil
        }
        guard let hostID = hostPeer?.id else { return }
        driverPeerID = hostID
        for index in connectedPeers.indices {
            connectedPeers[index].isDriver = false
        }
        if var hostPeer {
            hostPeer.isDriver = true
            self.hostPeer = hostPeer
        }
        broadcastToGuests(.controlRevoke(peerID: peerID))
        updatePresenceSnapshot()
    }
}
