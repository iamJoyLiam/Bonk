import Combine
import Foundation
import Network
import os.log

// MARK: - Relay Delegate

protocol TeamRelayDelegate: AnyObject {
    func teamRelay(_ relay: TeamRelay, didReceiveInput payload: String, from peerID: UUID)
    func teamRelay(_ relay: TeamRelay, didReceiveResize columns: Int, rows: Int, from peerID: UUID)
    func teamRelay(_ relay: TeamRelay, didUpdatePresence snapshot: TeamPresenceSnapshot)
    func teamRelay(_ relay: TeamRelay, didRequestControl peerID: UUID, displayName: String)
    func teamRelayDidGuestConnect(_ relay: TeamRelay, peer: TeamPeer)
    func teamRelayDidGuestDisconnect(_ relay: TeamRelay, peerID: UUID)
}

// MARK: - Team Relay (Host + Guest in one, role-driven)

@MainActor
final class TeamRelay: ObservableObject {
    static let shared = TeamRelay()
    @Published private(set) var isHosting = false
    @Published private(set) var isConnected = false
    @Published private(set) var connectedPeers: [TeamPeer] = []
    @Published var driverPeerID: UUID?
    @Published var pairingPin: String?

    weak var delegate: TeamRelayDelegate?

    private let logger = Logger(subsystem: "com.bonk", category: "TeamRelay")
    private var hostListener: NWListener?
    private var hostedConnections: [UUID: NWConnection] = [:]
    private var hostedConnectionBuffers: [UUID: Data] = [:]
    private var guestConnection: NWConnection?
    private var guestBuffer = Data()
    private var replayBuffer: [String] = []
    private var replayByteCount = 0
    private var hostPeer: TeamPeer?
    private var isHostMode = false

    // MARK: - Host

    func startHosting(displayName: String) {
        guard !isHosting else { return }
        isHostMode = true
        let localPeerID = UUID()
        hostPeer = TeamPeer(id: localPeerID, displayName: displayName, role: .host, isDriver: true)
        driverPeerID = localPeerID
        pairingPin = generatePin()
        do {
            let parameters = NWParameters.tcp
            // MVP: plain TCP; TLS can be added via NWParameters.tls later without API change
            hostListener = try NWListener(using: parameters)
            hostListener?.stateUpdateHandler = { [weak self] state in
                self?.logger.info("Host listener state: \(String(describing: state))")
            }
            hostListener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handleNewHostConnection(connection) }
            }
            hostListener?.start(queue: .global(qos: .utility))
            isHosting = true
            logger.info("Hosting team relay on \(String(describing: self.hostListener?.port)) pin=\(self.pairingPin ?? "-", privacy: .private)")
            updatePresenceSnapshot()
        } catch {
            logger.error("Failed to start host listener: \(error.localizedDescription)")
        }
    }

    func stopHosting() {
        hostListener?.cancel()
        hostListener = nil
        for connection in hostedConnections.values { connection.cancel() }
        hostedConnections.removeAll()
        hostedConnectionBuffers.removeAll()
        isHosting = false
        isHostMode = false
        pairingPin = nil
        connectedPeers.removeAll()
        replayBuffer.removeAll()
        replayByteCount = 0
    }

    var hostedPort: UInt16? {
        guard let raw = hostListener?.port?.rawValue else { return nil }
        return raw
    }

    // MARK: - Guest

    func connectToHost(endpoint: NWEndpoint, displayName: String, pin: String) {
        isHostMode = false
        let localPeerID = UUID()
        let guestPeer = TeamPeer(id: localPeerID, displayName: displayName, role: .guest)
        // Store for later use
        guestConnection?.cancel()
        guestConnection = NWConnection(to: endpoint, using: .tcp)
        guestConnection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("Guest connected to host")
                Task { @MainActor in
                    self?.isConnected = true
                    // Send pairing first
                    self?.sendToGuest(.pairingChallenge(pin: pin))
                    self?.receiveOnGuestConnection()
                }
            case .failed(let error):
                self?.logger.error("Guest failed: \(error.localizedDescription)")
                Task { @MainActor in self?.isConnected = false }
            case .cancelled:
                Task { @MainActor in self?.isConnected = false }
            default: break
            }
        }
        guestConnection?.start(queue: .global(qos: .utility))
        // Keep guestPeer for presence (host will echo back)
        _ = guestPeer
        logger.info("Guest connecting to \(String(describing: endpoint))")
    }

    func disconnectGuest() {
        guestConnection?.cancel()
        guestConnection = nil
        isConnected = false
        guestBuffer.removeAll()
    }

    // MARK: - Host: handle new connection

    private func handleNewHostConnection(_ connection: NWConnection) {
        let peerConnectionID = UUID()
        hostedConnections[peerConnectionID] = connection
        hostedConnectionBuffers[peerConnectionID] = Data()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("Host accepted connection \(peerConnectionID.uuidString.prefix(8))")
                Task { @MainActor in self?.receiveOnHostConnection(peerConnectionID: peerConnectionID) }
                // Send replay + presence
                Task { @MainActor in
                    self?.sendReplay(to: peerConnectionID)
                    self?.updatePresenceSnapshot()
                }
            case .failed(let error):
                self?.logger.error("Host connection failed: \(error.localizedDescription)")
                Task { @MainActor in self?.removeHostConnection(peerConnectionID) }
            case .cancelled:
                Task { @MainActor in self?.removeHostConnection(peerConnectionID) }
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private func removeHostConnection(_ peerConnectionID: UUID) {
        hostedConnections[peerConnectionID]?.cancel()
        hostedConnections.removeValue(forKey: peerConnectionID)
        hostedConnectionBuffers.removeValue(forKey: peerConnectionID)
        if let index = connectedPeers.firstIndex(where: { $0.id == peerConnectionID }) {
            connectedPeers.remove(at: index)
            delegate?.teamRelayDidGuestDisconnect(self, peerID: peerConnectionID)
            updatePresenceSnapshot()
        }
    }

    // MARK: - Messaging (newline-delimited JSON)

    private func sendMessage(_ message: TeamMessage, to connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(message) else { return }
        var framed = payload
        framed.append(0x0A) // newline
        connection.send(content: framed, completion: .contentProcessed({ _ in }))
    }

    private func sendToGuest(_ message: TeamMessage) {
        guard let connection = guestConnection else { return }
        sendMessage(message, to: connection)
    }

    private func broadcastToGuests(_ message: TeamMessage) {
        for connection in hostedConnections.values { sendMessage(message, to: connection) }
    }

    // MARK: - Host receive

    private func receiveOnHostConnection(peerConnectionID: UUID) {
        guard let connection = hostedConnections[peerConnectionID] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in self.handleHostData(data, peerConnectionID: peerConnectionID) }
            }
            if let error {
                self.logger.error("Host receive error: \(error.localizedDescription)")
                Task { @MainActor in self.removeHostConnection(peerConnectionID) }
                return
            }
            if isComplete {
                Task { @MainActor in self.removeHostConnection(peerConnectionID) }
                return
            }
            Task { @MainActor in self.receiveOnHostConnection(peerConnectionID: peerConnectionID) }
        }
    }

    private func handleHostData(_ data: Data, peerConnectionID: UUID) {
        var buffer = hostedConnectionBuffers[peerConnectionID] ?? Data()
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer = buffer.suffix(from: buffer.index(after: newlineIndex))
            if lineData.isEmpty { continue }
            guard let message = try? JSONDecoder().decode(TeamMessage.self, from: lineData) else {
                logger.warning("Host failed to decode message")
                continue
            }
            handleHostMessage(message, peerConnectionID: peerConnectionID)
        }
        hostedConnectionBuffers[peerConnectionID] = buffer
    }

    private func handleHostMessage(_ message: TeamMessage, peerConnectionID: UUID) {
        switch message {
        case let .pairingChallenge(pin):
            guard pin == pairingPin else {
                logger.warning("Host pairing PIN mismatch")
                removeHostConnection(peerConnectionID)
                return
            }
            // Create guest peer entry
            let guestPeer = TeamPeer(id: peerConnectionID, displayName: "Guest-\(peerConnectionID.uuidString.prefix(4))", role: .guest)
            if !connectedPeers.contains(where: { $0.id == peerConnectionID }) {
                connectedPeers.append(guestPeer)
                delegate?.teamRelayDidGuestConnect(self, peer: guestPeer)
                updatePresenceSnapshot()
            }
        case let .terminalInput(payload):
            // Floor control: only driver may send input
            guard driverPeerID == peerConnectionID else {
                logger.info("Host ignoring input from non-driver \(peerConnectionID.uuidString.prefix(8))")
                return
            }
            if let delegate {
                delegate.teamRelay(self, didReceiveInput: payload, from: peerConnectionID)
            } else {
                // Fallback: directly forward to active PTY (MVP without delegate wiring)
                Task { @MainActor in
                    guard let sessionManager = BonkAppDelegate.shared?.sessionManager,
                          let tabID = sessionManager.activeTabID,
                          let data = payload.data(using: .utf8)
                    else { return }
                    let bytes = Array(data)
                    try? await sessionManager.sendInput(bytes[...], to: tabID)
                }
            }
        case let .resize(columns, rows):
            delegate?.teamRelay(self, didReceiveResize: columns, rows: rows, from: peerConnectionID)
        case let .controlRequest(_, displayName):
            delegate?.teamRelay(self, didRequestControl: peerConnectionID, displayName: displayName)
        case .heartbeat:
            sendMessage(.heartbeat, to: hostedConnections[peerConnectionID]!)
        default:
            break
        }
    }

    // MARK: - Guest receive

    private func receiveOnGuestConnection() {
        guard let connection = guestConnection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in self.handleGuestData(data) }
            }
            if let error {
                self.logger.error("Guest receive error: \(error.localizedDescription)")
                Task { @MainActor in self.isConnected = false }
                return
            }
            if isComplete {
                Task { @MainActor in self.isConnected = false }
                return
            }
            Task { @MainActor in self.receiveOnGuestConnection() }
        }
    }

    private func handleGuestData(_ data: Data) {
        guestBuffer.append(data)
        while let newlineIndex = guestBuffer.firstIndex(of: 0x0A) {
            let lineData = guestBuffer.prefix(upTo: newlineIndex)
            guestBuffer = guestBuffer.suffix(from: guestBuffer.index(after: newlineIndex))
            if lineData.isEmpty { continue }
            guard let message = try? JSONDecoder().decode(TeamMessage.self, from: lineData) else {
                logger.warning("Guest failed to decode message")
                continue
            }
            handleGuestMessage(message)
        }
    }

    private func handleGuestMessage(_ message: TeamMessage) {
        switch message {
        case let .terminalOutput(payload):
            // Guest renders this via delegate or published state
            // For MVP, delegate can feed to terminal view
            // We reuse the same delegate path as host input but for output
            // Instead post notification for guest terminal view to append
            NotificationCenter.default.post(name: .teamGuestDidReceiveOutput, object: nil, userInfo: ["payload": payload])
        case let .presenceSnapshot(snapshot):
            delegate?.teamRelay(self, didUpdatePresence: snapshot)
        case let .peerJoined(peer):
            delegate?.teamRelayDidGuestConnect(self, peer: peer)
        case let .peerLeft(peerID):
            delegate?.teamRelayDidGuestDisconnect(self, peerID: peerID)
        case let .controlGrant(peerID):
            driverPeerID = peerID
            updatePresenceSnapshot()
        case .heartbeat:
            sendToGuest(.heartbeat)
        default:
            break
        }
    }

    // MARK: - Host broadcast API (called by PTY)

    func broadcastOutput(_ chunk: String) {
        guard isHostMode else { return }
        appendReplay(chunk)
        broadcastToGuests(.terminalOutput(payload: chunk))
    }

    func broadcastResize(columns: Int, rows: Int) {
        broadcastToGuests(.resize(columns: columns, rows: rows))
    }

    // MARK: - Guest send API

    func sendInputFromGuest(_ payload: String) {
        sendToGuest(.terminalInput(payload: payload))
    }

    func sendControlRequest(displayName: String, peerID: UUID) {
        sendToGuest(.controlRequest(peerID: peerID, displayName: displayName))
    }

    // MARK: - Control (Host)

    func grantControl(to peerID: UUID) {
        driverPeerID = peerID
        broadcastToGuests(.controlGrant(peerID: peerID))
        if let index = connectedPeers.firstIndex(where: { $0.id == peerID }) {
            for peerIndex in connectedPeers.indices { connectedPeers[peerIndex].isDriver = (connectedPeers[peerIndex].id == peerID) }
            connectedPeers[index].isDriver = true
        }
        if var hosted = hostPeer {
            hosted.isDriver = (hosted.id == peerID)
            hostPeer = hosted
        }
        updatePresenceSnapshot()
    }

    func revokeControl(from peerID: UUID) {
        // Return to host
        if let hostID = hostPeer?.id {
            driverPeerID = hostID
            broadcastToGuests(.controlRevoke(peerID: peerID))
            if var hosted = hostPeer {
                hosted.isDriver = true
                hostPeer = hosted
            }
            for peerIndex in connectedPeers.indices { connectedPeers[peerIndex].isDriver = false }
            updatePresenceSnapshot()
        }
    }

    // MARK: - Replay

    private func appendReplay(_ chunk: String) {
        replayBuffer.append(chunk)
        replayByteCount += chunk.utf8.count
        while replayByteCount > TeamConstants.replayBufferByteLimit || replayBuffer.count > TeamConstants.replayBufferLineLimit {
            if let removed = replayBuffer.first {
                replayByteCount -= removed.utf8.count
                replayBuffer.removeFirst()
            } else { break }
        }
    }

    private func sendReplay(to peerConnectionID: UUID) {
        guard let connection = hostedConnections[peerConnectionID] else { return }
        for chunk in replayBuffer { sendMessage(.terminalOutput(payload: chunk), to: connection) }
    }

    private func updatePresenceSnapshot() {
        guard let host = hostPeer else { return }
        let snapshot = TeamPresenceSnapshot(hostPeer: host, guestPeers: connectedPeers, driverPeerID: driverPeerID)
        broadcastToGuests(.presenceSnapshot(snapshot: snapshot))
        delegate?.teamRelay(self, didUpdatePresence: snapshot)
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
