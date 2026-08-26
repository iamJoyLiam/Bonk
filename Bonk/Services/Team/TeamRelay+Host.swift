import Foundation
import Network
import os.log

// MARK: - Host: handle connection

extension TeamRelay {
    func handleNewHostConnection(_ connection: NWConnection) {
        guard isHosting else {
            connection.cancel()
            return
        }

        let peerConnectionID = UUID()
        hostedConnections[peerConnectionID] = connection
        hostedFramers[peerConnectionID] = TeamMessageFramer()
        hostLastActivity[peerConnectionID] = Date()

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.logger.info("Host accepted connection \(peerConnectionID.uuidString.prefix(8))")
                    self.startHostPairingTimeout(for: peerConnectionID)
                    self.receiveOnHostConnection(peerConnectionID: peerConnectionID)
                    self.updatePresenceSnapshot()
                case .failed(let error):
                    self.logger.error("Host connection failed: \(error.localizedDescription)")
                    self.removeHostConnection(peerConnectionID)
                case .cancelled:
                    self.removeHostConnection(peerConnectionID)
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    func startHostPairingTimeout(for peerConnectionID: UUID) {
        hostPairingTimeoutTasks[peerConnectionID]?.cancel()
        hostPairingTimeoutTasks[peerConnectionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TeamConstants.connectionTimeoutSeconds))
            guard let self,
                  !Task.isCancelled,
                  self.hostedConnections[peerConnectionID] != nil,
                  !self.isPaired(peerConnectionID)
            else { return }
            self.rejectHostConnection(peerConnectionID, reason: "配对超时")
        }
    }

    func startHostHeartbeat(for peerConnectionID: UUID) {
        hostHeartbeatTasks[peerConnectionID]?.cancel()
        hostHeartbeatTasks[peerConnectionID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TeamConstants.heartbeatIntervalSeconds))
                guard let self,
                      self.hostedConnections[peerConnectionID] != nil,
                      self.isPaired(peerConnectionID)
                else { return }

                let lastActivity = self.hostLastActivity[peerConnectionID] ?? .distantPast
                if Date().timeIntervalSince(lastActivity) > Self.heartbeatTimeout {
                    self.removeHostConnection(peerConnectionID)
                    return
                }
                if let connection = self.hostedConnections[peerConnectionID] {
                    self.sendMessage(.heartbeat, to: connection)
                }
            }
        }
    }

    func removeHostConnection(_ peerConnectionID: UUID) {
        hostedConnections[peerConnectionID]?.cancel()
        hostedConnections.removeValue(forKey: peerConnectionID)
        hostedFramers.removeValue(forKey: peerConnectionID)
        hostLastActivity.removeValue(forKey: peerConnectionID)
        hostHeartbeatTasks.removeValue(forKey: peerConnectionID)?.cancel()
        hostPairingTimeoutTasks.removeValue(forKey: peerConnectionID)?.cancel()

        guard let index = connectedPeers.firstIndex(where: { $0.id == peerConnectionID }) else {
            return
        }

        let peerName = connectedPeers[index].displayName
        peerDisconnectedNotice = "访客 \(peerName) 已断开"
        connectedPeers.remove(at: index)
        if pendingControlRequest?.peerID == peerConnectionID {
            pendingControlRequest = nil
        }
        if driverPeerID == peerConnectionID {
            driverPeerID = hostPeer?.id
            if var hostPeer {
                hostPeer.isDriver = true
                self.hostPeer = hostPeer
            }
            for index in connectedPeers.indices {
                connectedPeers[index].isDriver = false
            }
            broadcastToGuests(.controlRevoke(peerID: peerConnectionID))
        }
        updatePresenceSnapshot()
    }

    func isPaired(_ peerConnectionID: UUID) -> Bool {
        connectedPeers.contains { $0.id == peerConnectionID }
    }

    func rejectHostConnection(_ peerConnectionID: UUID, reason: String) {
        guard let connection = hostedConnections[peerConnectionID] else { return }
        sendMessage(.pairingRejected(reason: reason), to: connection)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  self.hostedConnections[peerConnectionID] != nil,
                  !self.isPaired(peerConnectionID)
            else { return }
            self.removeHostConnection(peerConnectionID)
        }
    }
}

// MARK: - Host receive

extension TeamRelay {
    func receiveOnHostConnection(peerConnectionID: UUID) {
        guard let connection = hostedConnections[peerConnectionID] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handleHostData(data, peerConnectionID: peerConnectionID)
                }
            }
            if let error {
                self.logger.error("Host receive error: \(error.localizedDescription)")
                Task { @MainActor in
                    self.removeHostConnection(peerConnectionID)
                }
                return
            }
            if isComplete {
                Task { @MainActor in
                    self.removeHostConnection(peerConnectionID)
                }
                return
            }
            Task { @MainActor in
                self.receiveOnHostConnection(peerConnectionID: peerConnectionID)
            }
        }
    }

    func handleHostData(_ data: Data, peerConnectionID: UUID) {
        guard hostedConnections[peerConnectionID] != nil else { return }
        hostLastActivity[peerConnectionID] = Date()

        var framer = hostedFramers[peerConnectionID] ?? TeamMessageFramer()
        do {
            for frame in try framer.append(data) {
                let message = try JSONDecoder().decode(TeamMessage.self, from: frame)
                handleHostMessage(message, peerConnectionID: peerConnectionID)
            }
            hostedFramers[peerConnectionID] = framer
        } catch {
            logger.warning("Host rejected malformed team frame")
            removeHostConnection(peerConnectionID)
        }
    }

    func handleHostMessage(_ message: TeamMessage, peerConnectionID: UUID) {
        switch message {
        case let .pairingChallenge(pin, peer):
            guard !isPaired(peerConnectionID) else { return }
            guard connectedPeers.count < TeamConstants.maxGuestCount else {
                rejectHostConnection(peerConnectionID, reason: "主持端已达到访客上限")
                return
            }
            guard allowPairingAttempt() else {
                rejectHostConnection(peerConnectionID, reason: "配对尝试过多，请稍后再试")
                return
            }
            guard pin == pairingPin else {
                recordPairingFailure()
                logger.warning("Host pairing PIN mismatch")
                rejectHostConnection(peerConnectionID, reason: "PIN 不正确")
                return
            }

            hostPairingTimeoutTasks.removeValue(forKey: peerConnectionID)?.cancel()
            let guestPeer = TeamPeer(
                id: peerConnectionID,
                displayName: sanitizedDisplayName(peer.displayName, fallback: "Guest"),
                role: .guest
            )
            connectedPeers.append(guestPeer)
            startHostHeartbeat(for: peerConnectionID)
            updatePresenceSnapshot()
            sendReplay(to: peerConnectionID)
            if let connection = hostedConnections[peerConnectionID] {
                sendMessage(.notice(payload: "[Connected]\r\n"), to: connection)
            }
            if sharedSessionID == nil,
               let connection = hostedConnections[peerConnectionID]
            {
                sendMessage(
                    .notice(payload: "主持端当前没有可共享的终端，请先打开或连接一个终端。\n"),
                    to: connection
                )
            }

        case let .terminalInput(sessionID, payload):
            guard isPaired(peerConnectionID),
                  driverPeerID == peerConnectionID,
                  sessionID == sharedSessionID
            else {
                return
            }
            let peerName = connectedPeers.first(where: { $0.id == peerConnectionID })?.displayName ?? "Guest"
            markTyping(peerID: peerConnectionID, displayName: peerName)
            forwardInput(payload, to: sessionID)

        case let .resize(sessionID, columns, rows):
            guard isPaired(peerConnectionID),
                  driverPeerID == peerConnectionID,
                  sessionID == sharedSessionID
            else {
                return
            }
            forwardResize(columns: columns, rows: rows, to: sessionID)

        case let .controlRequest(_, displayName):
            guard isPaired(peerConnectionID) else { return }
            pendingControlRequest = (
                peerID: peerConnectionID,
                displayName: sanitizedDisplayName(displayName, fallback: "Guest")
            )

        case let .shareHosts(hosts):
            guard isPaired(peerConnectionID) else { return }
            pendingShareHosts = hosts

        case .heartbeat:
            hostLastActivity[peerConnectionID] = Date()
            if let connection = hostedConnections[peerConnectionID] {
                sendMessage(.heartbeat, to: connection)
            }

        case let .typing(peerID, displayName):
            guard isPaired(peerConnectionID) else { return }
            markTyping(peerID: peerID, displayName: displayName)

        default:
            break
        }
    }

    func forwardInput(_ payload: String, to sessionID: TeamSessionID) {
        guard let sessionManager = BonkAppDelegate.shared?.sessionManager,
              let data = payload.data(using: .utf8)
        else { return }
        let bytes = Array(data)
        Task { @MainActor in
            try? await sessionManager.sendInput(
                bytes[...],
                to: sessionID.tabID,
                paneID: sessionID.paneID
            )
        }
    }

    func forwardResize(columns: Int, rows: Int, to sessionID: TeamSessionID) {
        guard let sessionManager = BonkAppDelegate.shared?.sessionManager else { return }
        Task { @MainActor in
            try? await sessionManager.resizePTY(
                cols: columns,
                rows: rows,
                tabID: sessionID.tabID,
                paneID: sessionID.paneID
            )
        }
    }
}
