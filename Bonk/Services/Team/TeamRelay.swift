import Combine
import Foundation
import Network
import os.log

// MARK: - Team Relay (Host + Guest in one, role-driven)

@MainActor
final class TeamRelay: ObservableObject {
    static let shared = TeamRelay()

    @Published var isHosting = false // TODO: delegate to TeamStore.isHosting (Phase 4 takeover)
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
    @Published var sharedSessionLostNotice: String?
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

    @Published var typingPeerName: String?
    var typingClearTask: Task<Void, Never>?

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
        // Best-effort notify paired guests before teardown
        let disconnectNotice = TeamMessage.notice(payload: "主持人已结束共享")
        for (peerID, connection) in hostedConnections where isPaired(peerID) {
            sendMessage(disconnectNotice, to: connection)
        }
        hostListener?.cancel()
        hostListener = nil
        let pendingConnections = hostedConnections
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            for connection in pendingConnections.values {
                connection.cancel()
            }
        }
        for task in hostHeartbeatTasks.values { task.cancel() }
        for task in hostPairingTimeoutTasks.values { task.cancel() }
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
            // Also surface as peerDisconnectedNotice so Team window shows it
            if hasPaired {
                peerDisconnectedNotice = error
            }
        } else if !hasPaired, isConnected {
            peerDisconnectedNotice = "主持人已断开连接"
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
}

// MARK: - Notifications

extension Notification.Name {
    static let teamGuestDidReceiveOutput = Notification.Name("teamGuestDidReceiveOutput")
    static let teamPresenceDidChange = Notification.Name("teamPresenceDidChange")
    static let teamMaxGuestsDidChange = Notification.Name("teamMaxGuestsDidChange")
}
