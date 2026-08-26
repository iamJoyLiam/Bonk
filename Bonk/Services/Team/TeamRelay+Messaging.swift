import Foundation
import Network
import os.log

// MARK: - Messaging

extension TeamRelay {
    func sendMessage(_ message: TeamMessage, to connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(message) else {
            logger.error("Failed to encode team message")
            return
        }
        guard payload.count <= TeamConstants.maxFrameBytes else {
            logger.error("Team message exceeds frame limit")
            return
        }

        var framed = payload
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.logger.error("Team send failed: \(error.localizedDescription)")
            }
        })
    }

    func sendToGuest(_ message: TeamMessage) {
        guard let connection = guestConnection else { return }
        sendMessage(message, to: connection)
    }

    func broadcastToGuests(_ message: TeamMessage) {
        guard let payload = try? JSONEncoder().encode(message) else {
            logger.error("Failed to encode team message")
            return
        }
        guard payload.count <= TeamConstants.maxFrameBytes else {
            logger.error("Team message exceeds frame limit")
            return
        }
        var framed = payload
        framed.append(0x0A)
        for (peerID, connection) in hostedConnections where isPaired(peerID) {
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.logger.error("Team send failed: \(error.localizedDescription)")
                }
            })
        }
    }
}
