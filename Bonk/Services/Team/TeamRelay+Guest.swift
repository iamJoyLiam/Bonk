import Foundation
import Network
import os.log

// MARK: - Guest receive

extension TeamRelay {
    func receiveOnGuestConnection(generation: UInt64) {
        guard let connection = guestConnection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    guard self.guestConnectionGeneration == generation else { return }
                    self.handleGuestData(data)
                }
            }
            if let error {
                self.logger.error("Guest receive error: \(error.localizedDescription)")
                Task { @MainActor in
                    self.finishGuestConnection(
                        generation: generation,
                        error: self.hasPaired ? nil : "连接被拒绝，请检查 IP/Port/PIN"
                    )
                }
                return
            }
            if isComplete {
                Task { @MainActor in
                    self.finishGuestConnection(generation: generation, error: nil)
                }
                return
            }
            Task { @MainActor in
                guard self.guestConnectionGeneration == generation else { return }
                self.receiveOnGuestConnection(generation: generation)
            }
        }
    }

    func handleGuestData(_ data: Data) {
        guestLastActivity = Date()
        do {
            for frame in try guestFramer.append(data) {
                let message = try JSONDecoder().decode(TeamMessage.self, from: frame)
                handleGuestMessage(message)
            }
        } catch {
            logger.warning("Guest rejected malformed team frame")
            finishGuestConnection(generation: guestConnectionGeneration, error: "主机发送了无效数据")
        }
    }

    func handleGuestMessage(_ message: TeamMessage) {
        switch message {
        case let .terminalOutput(sessionID, payload):
            guard sharedSessionID == nil || sharedSessionID == sessionID else { return }
            sharedSessionID = sessionID
            hasPaired = true
            queueGuestOutput(payload)

        case let .notice(payload):
            hasPaired = true
            queueGuestOutput(payload)

        case let .presenceSnapshot(snapshot):
            hasPaired = true
            guestPairingTimeoutTask?.cancel()
            guestPairingTimeoutTask = nil
            let previousSessionID = sharedSessionID
            hostPeerID = snapshot.hostPeer.id
            driverPeerID = snapshot.driverPeerID
            sharedSessionID = snapshot.sharedSessionID
            connectedPeers = snapshot.guestPeers
            if previousSessionID != snapshot.sharedSessionID {
                resetGuestOutput()
                if snapshot.sharedSessionID == nil && previousSessionID != nil {
                    sharedSessionLostNotice = "主持人已关闭共享终端"
                }
            }

        case let .peerJoined(peer):
            hasPaired = true
            if !connectedPeers.contains(where: { $0.id == peer.id }) {
                connectedPeers.append(peer)
            }

        case let .peerLeft(peerID):
            connectedPeers.removeAll { $0.id == peerID }
            if driverPeerID == peerID {
                driverPeerID = hostPeerID
            }

        case let .controlGrant(peerID):
            driverPeerID = peerID

        case let .controlRevoke(peerID):
            if driverPeerID == peerID {
                driverPeerID = hostPeerID
                controlRevokedNotice = "主持人已收回控制权，需重新请求授权"
            }

        case let .shareHosts(hosts):
            pendingShareHosts = hosts

        case let .pairingRejected(reason):
            finishGuestConnection(
                generation: guestConnectionGeneration,
                error: reason
            )

        case .heartbeat:
            sendToGuest(.heartbeat)

        case let .typing(peerID, displayName):
            markTyping(peerID: peerID, displayName: displayName)

        default:
            break
        }
    }
}

// MARK: - Guest output buffering

extension TeamRelay {
    func queueGuestOutput(_ payload: String) {
        guard !payload.isEmpty else { return }
        pendingGuestOutput.append(payload)
        scheduleGuestOutputFlush()
    }

    func scheduleGuestOutputFlush() {
        guard guestOutputFlushTask == nil else { return }
        guestOutputFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.guestOutputFlushInterval)
            guard !Task.isCancelled else { return }
            self?.flushGuestOutput()
        }
    }

    func flushGuestOutput() {
        guestOutputFlushTask = nil
        guard !pendingGuestOutput.isEmpty else { return }
        let payload = pendingGuestOutput
        pendingGuestOutput.removeAll(keepingCapacity: true)
        appendGuestReplay(payload)
        guestOutputRevision &+= 1
        NotificationCenter.default.post(
            name: .teamGuestDidReceiveOutput,
            object: nil,
            userInfo: [
                "payload": payload,
                "revision": guestOutputRevision
            ]
        )
    }

    func appendGuestReplay(_ payload: String) {
        guestOutputReplay.append(payload)
        guestOutputByteCount += payload.utf8.count
        let maxBytes = TeamConstants.replayBufferByteLimit
        if guestOutputByteCount > maxBytes {
            let data = Data(guestOutputReplay.utf8)
            let suffix = data.suffix(maxBytes)
            var decoded: String? = nil
            for offset in 0..<min(4, suffix.count) {
                let slice = suffix.dropFirst(offset)
                if let str = String(data: slice, encoding: .utf8) {
                    decoded = str
                    break
                }
            }
            guestOutputReplay = decoded ?? String(decoding: suffix, as: UTF8.self)
            guestOutputByteCount = guestOutputReplay.utf8.count
        }
    }

    func resetGuestOutput() {
        guestOutputFlushTask?.cancel()
        guestOutputFlushTask = nil
        pendingGuestOutput.removeAll(keepingCapacity: true)
        guestOutputReplay.removeAll(keepingCapacity: true)
        guestOutputByteCount = 0
        guestOutputRevision = 0
    }

    func guestOutputSnapshot() -> (revision: UInt64, payload: String) {
        (guestOutputRevision, guestOutputReplay)
    }
}

// MARK: - Guest send API

extension TeamRelay {
    func sendInputFromGuest(_ payload: String, sessionID: TeamSessionID? = nil) {
        guard let sessionID = sessionID ?? sharedSessionID else { return }
        if let guestPeer {
            markTyping(peerID: guestPeer.id, displayName: guestPeer.displayName)
        }
        sendToGuest(.terminalInput(sessionID: sessionID, payload: payload))
    }

    func sendResizeFromGuest(columns: Int, rows: Int) {
        guard let sessionID = sharedSessionID else { return }
        sendToGuest(.resize(sessionID: sessionID, columns: columns, rows: rows))
    }

    func sendControlRequest(displayName: String) {
        guard let guestPeer else { return }
        sendToGuest(.controlRequest(peerID: guestPeer.id, displayName: displayName))
    }

    func shareHosts(_ hosts: [HostItemExport]) {
        guard !hosts.isEmpty else { return }
        let message = TeamMessage.shareHosts(hosts: hosts)
        if isHosting {
            broadcastToGuests(message)
        } else if isConnected {
            sendToGuest(message)
        }
    }
}
