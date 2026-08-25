import Combine
import Foundation
import Network
import os.log

// MARK: - Team Relay (Host + Guest in one, role-driven)

@MainActor
final class TeamRelay: ObservableObject {
    static let shared = TeamRelay()

    @Published private(set) var isHosting = false
    @Published private(set) var isConnected = false
    @Published private(set) var connectedPeers: [TeamPeer] = []
    @Published private(set) var sharedSessionID: TeamSessionID?
    @Published var driverPeerID: UUID?
    @Published var hostPeerID: UUID?
    @Published var pairingPin: String?
    @Published var lastError: String?
    @Published var pendingControlRequest: (peerID: UUID, displayName: String)?
    @Published var controlRevokedNotice: String?
    @Published var peerDisconnectedNotice: String?
    @Published var pendingShareHosts: [HostItemExport]?
    @Published private(set) var hostedPort: UInt16?

    private let logger = Logger(subsystem: "com.bonk", category: "TeamRelay")
    private var hostListener: NWListener?
    private var hostedConnections: [UUID: NWConnection] = [:]
    private var hostedFramers: [UUID: TeamMessageFramer] = [:]
    private(set) var hostPeer: TeamPeer?
    private var hostHeartbeatTasks: [UUID: Task<Void, Never>] = [:]
    private var hostPairingTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var hostLastActivity: [UUID: Date] = [:]

    private var guestConnection: NWConnection?
    private var guestFramer = TeamMessageFramer()
    private var guestPeer: TeamPeer?
    private var guestHeartbeatTask: Task<Void, Never>?
    private var guestPairingTimeoutTask: Task<Void, Never>?
    private var guestLastActivity = Date.distantPast
    private var guestConnectionGeneration: UInt64 = 0
    private var hasPaired = false

    private var isHostMode = false
    private var pairingFailureTimestamps: [Date] = []
    private var replayBuffer: [ReplayChunk] = []
    private var replayByteCount = 0
    private var pendingGuestOutput = ""
    private var guestOutputReplay = ""
    private var guestOutputRevision: UInt64 = 0
    private var guestOutputFlushTask: Task<Void, Never>?

    private static let guestOutputFlushInterval = Duration.milliseconds(16)
    private static let heartbeatTimeout: TimeInterval = max(
        TeamConstants.connectionTimeoutSeconds,
        TeamConstants.heartbeatIntervalSeconds * 2
    )

    private struct ReplayChunk {
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

    private func cancelGuestResources() {
        guestConnection?.cancel()
        guestConnection = nil
        guestHeartbeatTask?.cancel()
        guestHeartbeatTask = nil
        guestPairingTimeoutTask?.cancel()
        guestPairingTimeoutTask = nil
        guestFramer = TeamMessageFramer()
    }

    private func finishGuestConnection(generation: UInt64, error: String?) {
        guard generation == guestConnectionGeneration else { return }
        if let error {
            lastError = error
        } else if !hasPaired, isConnected {
            lastError = lastError ?? "PIN 不正确或主机已断开"
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

    private func startGuestPairingTimeout(generation: UInt64) {
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

    private func startGuestHeartbeat(generation: UInt64) {
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

    // MARK: - Host: handle connection

    private func handleNewHostConnection(_ connection: NWConnection) {
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

    private func startHostPairingTimeout(for peerConnectionID: UUID) {
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

    private func startHostHeartbeat(for peerConnectionID: UUID) {
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

    private func removeHostConnection(_ peerConnectionID: UUID) {
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

    private func isPaired(_ peerConnectionID: UUID) -> Bool {
        connectedPeers.contains { $0.id == peerConnectionID }
    }

    private func rejectHostConnection(_ peerConnectionID: UUID, reason: String) {
        guard let connection = hostedConnections[peerConnectionID] else { return }
        sendMessage(.pairingRejected(reason: reason), to: connection)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.hostedConnections[peerConnectionID] != nil else { return }
            self.removeHostConnection(peerConnectionID)
        }
    }

    // MARK: - Messaging

    private func sendMessage(_ message: TeamMessage, to connection: NWConnection) {
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

    private func sendToGuest(_ message: TeamMessage) {
        guard let connection = guestConnection else { return }
        sendMessage(message, to: connection)
    }

    private func broadcastToGuests(_ message: TeamMessage) {
        for (peerID, connection) in hostedConnections where isPaired(peerID) {
            sendMessage(message, to: connection)
        }
    }

    // MARK: - Host receive

    private func receiveOnHostConnection(peerConnectionID: UUID) {
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

    private func handleHostData(_ data: Data, peerConnectionID: UUID) {
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

    private func handleHostMessage(_ message: TeamMessage, peerConnectionID: UUID) {
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

        default:
            break
        }
    }

    private func forwardInput(_ payload: String, to sessionID: TeamSessionID) {
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

    private func forwardResize(columns: Int, rows: Int, to sessionID: TeamSessionID) {
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

    // MARK: - Guest receive

    private func receiveOnGuestConnection(generation: UInt64) {
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

    private func handleGuestData(_ data: Data) {
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

    private func handleGuestMessage(_ message: TeamMessage) {
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

        default:
            break
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

    // MARK: - Guest output buffering

    func guestOutputSnapshot() -> (revision: UInt64, payload: String) {
        (guestOutputRevision, guestOutputReplay)
    }

    private func queueGuestOutput(_ payload: String) {
        guard !payload.isEmpty else { return }
        pendingGuestOutput.append(payload)
        scheduleGuestOutputFlush()
    }

    private func scheduleGuestOutputFlush() {
        guard guestOutputFlushTask == nil else { return }
        guestOutputFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.guestOutputFlushInterval)
            guard !Task.isCancelled else { return }
            self?.flushGuestOutput()
        }
    }

    private func flushGuestOutput() {
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

    private func appendGuestReplay(_ payload: String) {
        guestOutputReplay.append(payload)
        let maxBytes = TeamConstants.replayBufferByteLimit
        if guestOutputReplay.utf8.count > maxBytes {
            guestOutputReplay = String(guestOutputReplay.suffix(maxBytes))
        }
    }

    private func resetGuestOutput() {
        guestOutputFlushTask?.cancel()
        guestOutputFlushTask = nil
        pendingGuestOutput.removeAll(keepingCapacity: true)
        guestOutputReplay.removeAll(keepingCapacity: true)
        guestOutputRevision = 0
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

    private func updatePresenceSnapshot() {
        guard let hostPeer else { return }
        let snapshot = TeamPresenceSnapshot(
            hostPeer: hostPeer,
            guestPeers: connectedPeers,
            driverPeerID: driverPeerID,
            sharedSessionID: sharedSessionID
        )
        broadcastToGuests(.presenceSnapshot(snapshot: snapshot))
    }

    private func appendReplay(sessionID: TeamSessionID, payload: String) {
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

    private func sendReplay(to peerConnectionID: UUID) {
        guard let connection = hostedConnections[peerConnectionID] else { return }
        for chunk in replayBuffer {
            sendMessage(
                .terminalOutput(sessionID: chunk.sessionID, payload: chunk.payload),
                to: connection
            )
        }
    }

    // MARK: - Pairing helpers

    private func allowPairingAttempt() -> Bool {
        let cutoff = Date().addingTimeInterval(-60)
        pairingFailureTimestamps.removeAll { $0 < cutoff }
        return pairingFailureTimestamps.count < TeamConstants.maxPairingFailuresPerMinute
    }

    private func recordPairingFailure() {
        pairingFailureTimestamps.append(Date())
    }

    private func sanitizedDisplayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(64))
    }

    private func currentActiveSessionID() -> TeamSessionID? {
        guard let sessionManager = BonkAppDelegate.shared?.sessionManager,
              let tab = sessionManager.activeTab,
              let paneID = tab.activePaneID
        else { return nil }
        return TeamSessionID(tabID: tab.id, paneID: paneID)
    }

    private func generatePin() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let teamGuestDidReceiveOutput = Notification.Name("teamGuestDidReceiveOutput")
    static let teamPresenceDidChange = Notification.Name("teamPresenceDidChange")
}
