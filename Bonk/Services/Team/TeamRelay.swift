import Combine
import Foundation
import Network
import os.log

// MARK: - Team Relay (Host + Guest in one, role-driven)

@MainActor
final class TeamRelay: ObservableObject {
    static let shared = TeamRelay()

    @Published var isHosting = false
    @Published var isConnected = false
    @Published var connectedPeers: [TeamPeer] = []
    @Published var sharedSessionID: TeamSessionID?
    @Published var driverPeerID: UUID?
    @Published var hostPeerID: UUID?
    @Published var pairingPin: String?
    @Published var lastError: String?
    @Published var pendingControlRequest: (peerID: UUID, displayName: String)?
    @Published var controlRevokedNotice: String?
    @Published var peerDisconnectedNotice: String?
    @Published var pendingShareHosts: [HostItemExport]?
    @Published var hostedPort: UInt16?

    let logger = Logger(subsystem: "com.bonk", category: "TeamRelay")
    var hostListener: NWListener?
    var hostedConnections: [UUID: NWConnection] = [:]
    var hostedFramers: [UUID: TeamMessageFramer] = [:]
    var hostPeer: TeamPeer?
    var hostHeartbeatTasks: [UUID: Task<Void, Never>] = [:]
    var hostPairingTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    var hostLastActivity: [UUID: Date] = [:]

    var guestConnection: NWConnection?
    var guestFramer = TeamMessageFramer()
    var guestPeer: TeamPeer?
    var guestHeartbeatTask: Task<Void, Never>?
    var guestPairingTimeoutTask: Task<Void, Never>?
    var guestLastActivity = Date.distantPast
    var guestConnectionGeneration: UInt64 = 0
    var hasPaired = false

    var isHostMode = false
    var pairingFailureTimestamps: [Date] = []
    var replayBuffer: [ReplayChunk] = []
    var replayByteCount = 0
    var pendingGuestOutput = ""
    var guestOutputReplay = ""
    var guestOutputByteCount = 0
    var guestOutputRevision: UInt64 = 0
    var guestOutputFlushTask: Task<Void, Never>?

    static let guestOutputFlushInterval = Duration.milliseconds(16)
    static let heartbeatTimeout: TimeInterval = max(
        TeamConstants.connectionTimeoutSeconds,
        TeamConstants.heartbeatIntervalSeconds * 2
    )

    struct ReplayChunk {
        let sessionID: TeamSessionID
        let payload: String
    }

    // MARK: - Host

    func startHosting(displayName: String) {
        guard !isHosting else { return }

        if guestConnection != nil {
            disconnectGuest()
        }

        isHostMode = true
        let localPeerID = UUID()
        hostPeer = TeamPeer(id: localPeerID, displayName: displayName, role: .host, isDriver: true)
        driverPeerID = localPeerID
        hostPeerID = localPeerID
        sharedSessionID = currentActiveSessionID()
        pairingPin = generatePin()

        do {
            let parameters = NWParameters.tcp
            hostListener = try NWListener(service: .init(name: displayName, type: TeamConstants.serviceType), using: parameters)
            let listener = hostListener
            hostListener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.logger.info("Host listener state: \(String(describing: state))")
                    if case .ready = state {
                        let raw = self.hostListener?.port?.rawValue
                        if let raw, raw != 0 {
                            self.hostedPort = raw
                        }
                    } else if case .failed = state {
                        self.hostedPort = nil
                    }
                }
            }
            hostListener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewHostConnection(connection)
                }
            }
            hostListener?.start(queue: .global(qos: .utility))
            isHosting = true
            if let raw = listener?.port?.rawValue, raw != 0 {
                hostedPort = raw
            }
            logger.info("Hosting team relay on \(String(describing: self.hostListener?.port))")
            updatePresenceSnapshot()
        } catch {
            logger.error("Failed to start host listener: \(error.localizedDescription)")
            resetHostState()
            lastError = "无法启动团队服务：\(error.localizedDescription)"
        }
    }

    func stopHosting() {
        hostListener?.cancel()
        hostListener = nil
        for connection in hostedConnections.values {
            connection.cancel()
        }
        for task in hostHeartbeatTasks.values {
            task.cancel()
        }
        for task in hostPairingTimeoutTasks.values {
            task.cancel()
        }
        resetHostState()
    }

    private func resetHostState() {
        hostedConnections.removeAll()
        hostedFramers.removeAll()
        hostHeartbeatTasks.removeAll()
        hostPairingTimeoutTasks.removeAll()
        hostLastActivity.removeAll()
        isHosting = false
        isHostMode = false
        pairingPin = nil
        hostedPort = nil
        hostPeer = nil
        hostPeerID = nil
        driverPeerID = nil
        sharedSessionID = nil
        connectedPeers.removeAll()
        pendingControlRequest = nil
        replayBuffer.removeAll()
        replayByteCount = 0
    }

    // MARK: - Guest

    func connectToHost(endpoint: NWEndpoint, displayName: String, pin: String) {
        if isHosting {
            stopHosting()
        }

        guestConnectionGeneration &+= 1
        let generation = guestConnectionGeneration
        cancelGuestResources()

        isHostMode = false
        isConnected = false
        hasPaired = false
        lastError = nil
        hostPeerID = nil
        driverPeerID = nil
        sharedSessionID = nil
        connectedPeers.removeAll()
        resetGuestOutput()

        let peer = TeamPeer(
            id: UUID(),
            displayName: sanitizedDisplayName(displayName, fallback: "Guest"),
            role: .guest
        )
        guestPeer = peer

        let connection = NWConnection(to: endpoint, using: .tcp)
        guestConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self,
                      self.guestConnectionGeneration == generation,
                      self.guestConnection === connection
                else { return }

                switch state {
                case .ready:
                    self.logger.info("Guest connected to host")
                    self.isConnected = true
                    self.guestLastActivity = Date()
                    self.sendToGuest(.pairingChallenge(pin: pin, peer: peer))
                    self.startGuestHeartbeat(generation: generation)
                    self.startGuestPairingTimeout(generation: generation)
                    self.receiveOnGuestConnection(generation: generation)
                case .failed(let error):
                    self.logger.error("Guest failed: \(error.localizedDescription)")
                    self.finishGuestConnection(
                        generation: generation,
                        error: "连接失败：\(error.localizedDescription)"
                    )
                case .cancelled:
                    self.finishGuestConnection(generation: generation, error: nil)
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .utility))
        logger.info("Guest connecting to \(String(describing: endpoint))")
    }

    func disconnectGuest() {
        guestConnectionGeneration &+= 1
        cancelGuestResources()
        isConnected = false
        hasPaired = false
        guestPeer = nil
        hostPeerID = nil
        driverPeerID = nil
        sharedSessionID = nil
        connectedPeers.removeAll()
        resetGuestOutput()
    }

    func cancelGuestResources() {
        guestConnection?.cancel()
        guestConnection = nil
        guestHeartbeatTask?.cancel()
        guestHeartbeatTask = nil
        guestPairingTimeoutTask?.cancel()
        guestPairingTimeoutTask = nil
        guestFramer = TeamMessageFramer()
    }

    func finishGuestConnection(generation: UInt64, error: String?) {
        guard generation == guestConnectionGeneration else { return }
        if let error {
            lastError = error
        } else if !hasPaired, isConnected {
            lastError = "PIN 不正确或主机已断开"
        } else if hasPaired, isConnected {
            // Host disconnected after successful pairing — notify guest explicitly
            peerDisconnectedNotice = "主持人已断开连接"
        }
        cancelGuestResources()
        isConnected = false
        hasPaired = false
        guestPeer = nil
        hostPeerID = nil
        driverPeerID = nil
        sharedSessionID = nil
        connectedPeers.removeAll()
    }

    func startGuestPairingTimeout(generation: UInt64) {
        guestPairingTimeoutTask?.cancel()
        guestPairingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TeamConstants.connectionTimeoutSeconds))
            guard let self,
                  !Task.isCancelled,
                  self.guestConnectionGeneration == generation,
                  self.isConnected,
                  !self.hasPaired
            else { return }
            self.finishGuestConnection(generation: generation, error: "团队配对超时")
        }
    }

    func startGuestHeartbeat(generation: UInt64) {
        guestHeartbeatTask?.cancel()
        guestHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TeamConstants.heartbeatIntervalSeconds))
                guard let self,
                      self.guestConnectionGeneration == generation,
                      self.isConnected
                else { return }

                if Date().timeIntervalSince(self.guestLastActivity) > Self.heartbeatTimeout {
                    self.finishGuestConnection(generation: generation, error: "主持端连接超时")
                    return
                }
                self.sendToGuest(.heartbeat)
            }
        }
    }

    // MARK: - Host broadcast API (called by PTY)

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

    // MARK: - Guest send API

    func sendInputFromGuest(_ payload: String, sessionID: TeamSessionID? = nil) {
        guard let sessionID = sessionID ?? sharedSessionID else { return }
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

    // MARK: - Control (Host)

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

    // MARK: - Presence / Replay

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

    // MARK: - Pairing helpers

    func allowPairingAttempt() -> Bool {
        let cutoff = Date().addingTimeInterval(-60)
        pairingFailureTimestamps.removeAll { $0 < cutoff }
        return pairingFailureTimestamps.count < TeamConstants.maxPairingFailuresPerMinute
    }

    func recordPairingFailure() {
        pairingFailureTimestamps.append(Date())
    }

    func sanitizedDisplayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(64))
    }

    func currentActiveSessionID() -> TeamSessionID? {
        guard let sessionManager = BonkAppDelegate.shared?.sessionManager,
              let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID
        else { return nil }
        return TeamSessionID(tabID: tab.id, paneID: paneID)
    }

    func generatePin() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let teamGuestDidReceiveOutput = Notification.Name("teamGuestDidReceiveOutput")
    static let teamPresenceDidChange = Notification.Name("teamPresenceDidChange")
    static let teamMaxGuestsDidChange = Notification.Name("teamMaxGuestsDidChange")
}
