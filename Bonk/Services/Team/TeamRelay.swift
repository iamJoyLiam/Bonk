import Combine
import Foundation
import Network
import os.log

// MARK: - Team Relay (Host + Guest in one, role-driven)

@MainActor
final class TeamRelay: ObservableObject {
    // Production singleton uses shared Store (single NWListener, single isHosting).
    // Tests create fresh Relays via TeamRelay() which get a fresh Store for isolation.
    static let shared: TeamRelay = {
        let row = TeamRelay(store: TeamStore.shared)
        return row
    }()

    @Published var isHosting = false // mirrors TeamStore.isHosting (single truth)
    @Published var isConnected = false
    // Injected SessionManager to break BonkAppDelegate.shared cycle (Phase 4)
    weak var injectedSessionManager: SessionManager?
    private let teamStore: TeamStore
    private var storeCancellables = Set<AnyCancellable>()
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
    /// The encrypted host. There is deliberately no `NWListener`: the relay has
    /// no plaintext path, so a plaintext client cannot connect even if it
    /// discovers the port.
    var sshHost: TeamSSHHost?
    var hostedConnections: [UUID: any TeamChannel] = [:]
    var hostedFramers: [UUID: TeamMessageFramer] = [:]
    var hostPeer: TeamPeer?
    var hostHeartbeatTasks: [UUID: Task<Void, Never>] = [:]
    var hostPairingTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    var hostLastActivity: [UUID: Date] = [:]

    var guestConnection: (any TeamChannel)?
    var guestFramer = TeamMessageFramer()
    var guestPeer: TeamPeer?
    /// Nonce generated for the current pairing attempt. The host must echo it
    /// in `pairingAccepted`; a mismatch means we are not talking to the peer
    /// that received our challenge.
    var guestPairingNonce: String?
    /// Fingerprint of the host we are paired with, for display and audit.
    @Published var hostIdentityFingerprint: String?
    /// Set when the host's fingerprint differs from the pinned one.
    @Published var hostIdentityChangedNotice: String?
    var guestHeartbeatTask: Task<Void, Never>?
    var guestPairingTimeoutTask: Task<Void, Never>?
    var guestLastActivity = Date.distantPast
    var guestConnectionGeneration: UInt64 = 0
    var hasPaired = false

    /// This machine's identity as a host, stable across restarts.
    private(set) lazy var hostIdentity: TeamHostIdentity = TeamIdentityStore.hostIdentity()

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

    init(store: TeamStore = TeamStore()) {
        self.teamStore = store
        // Single isHosting truth: Store owns listener, Relay mirrors published value
        teamStore.$isHosting.receive(on: DispatchQueue.main).sink { [weak self] value in
            guard let self else { return }
            if self.isHosting != value { self.isHosting = value }
        }.store(in: &storeCancellables)
        teamStore.$hostedPort.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.hostedPort = value
        }.store(in: &storeCancellables)
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

        let host = TeamSSHHost()
        sshHost = host
        // The PIN is the SSH credential. Mirroring it into the host before the
        // server starts means there is no window in which the relay accepts
        // connections with no PIN configured.
        host.update(pin: pairingPin)

        // `isHosting` is set *before* the server starts, not after. A guest on
        // the LAN can reach us the moment the socket is listening, and
        // `handleNewHostConnection` drops any channel that arrives while
        // `isHosting` is false — so setting it afterwards silently refuses
        // whoever connected first. A failed start rolls it back below.
        isHosting = true

        Task { [weak self] in
            guard let self else { return }
            let started = await host.start(displayName: displayName) { [weak self] channel in
                self?.handleNewHostConnection(channel)
            }
            guard started else {
                self.resetHostState()
                let message = L.t(.tmServiceStartFailed)
                self.lastError = message
                self.teamStore.didFailToStartHosting(message)
                return
            }
            self.hostedPort = host.port
            // Keep per-instance Store in sync (single truth for this Relay;
            // the shared Relay uses the shared Store).
            self.teamStore.didStartHosting(on: self.hostedPort)
            self.logger.info("Hosting team relay over SSH on port \(String(describing: self.hostedPort))")
            self.updatePresenceSnapshot()
        }
    }

    func stopHosting() {
        // Best-effort notify paired guests before teardown
        let disconnectNotice = TeamMessage.notice(payload: L.t(.tmHostEndedShare))
        for (peerID, connection) in hostedConnections where isPaired(peerID) {
            sendMessage(disconnectNotice, to: connection)
        }
        sshHost?.stop()
        sshHost = nil
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
        teamStore.stopHosting()
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

        guard let target = Self.resolve(endpoint) else {
            lastError = L.t(.aiConnectFailed)
            return
        }

        logger.info("Guest connecting over SSH to \(target.host):\(target.port)")
        let connector = TeamSSHGuest(
            host: target.host,
            port: target.port,
            displayName: peer.displayName,
            pin: pin,
            pinnedHostFingerprint: TeamIdentityStore.pinnedHostFingerprint()
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let channel = try await connector.connect()
                guard self.guestConnectionGeneration == generation else {
                    channel.cancel()
                    return
                }
                self.adoptGuestChannel(channel, peer: peer, generation: generation)
            } catch {
                // A real failure is reported as a failure. There is no
                // fallback to a plaintext socket, by design.
                self.logger.error("Guest SSH connect failed: \(error.localizedDescription)")
                self.finishGuestConnection(
                    generation: generation,
                    error: error.localizedDescription
                )
            }
        }
    }

    /// Install an authenticated channel and start the Team protocol on it.
    private func adoptGuestChannel(
        _ channel: SSHTeamChannel,
        peer: TeamPeer,
        generation: UInt64
    ) {
        guestConnection = channel
        isConnected = true
        guestLastActivity = Date()
        // Fresh nonce per attempt: it is what makes the host's acceptance
        // non-replayable. The PIN is not repeated here — SSH user
        // authentication already consumed it, and sending it twice would put
        // the credential on the wire a second time for no added protection.
        let nonce = Self.makePairingNonce()
        guestPairingNonce = nonce
        sendToGuest(.pairingChallenge(peer: peer, nonce: nonce))
        startGuestHeartbeat(generation: generation)
        startGuestPairingTimeout(generation: generation)
        receiveOnGuestConnection(generation: generation)
    }

    /// Resolve a discovered endpoint to a host and port.
    ///
    /// Bonjour hands back a `.service` endpoint, which carries no address; the
    /// browser already resolved it, so a manual-IP host short-circuits here and
    /// anything else is reported as unusable rather than guessed at.
    static func resolve(_ endpoint: NWEndpoint) -> (host: String, port: Int)? {
        switch endpoint {
        case let .hostPort(host, port):
            return (String(describing: host), Int(port.rawValue))
        default:
            return nil
        }
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
            peerDisconnectedNotice = L.t(.tmHostDisconnected)
            lastError = L.t(.tmPinOrGone)
        } else if hasPaired, isConnected {
            // Host disconnected after successful pairing — notify guest explicitly
            peerDisconnectedNotice = L.t(.tmHostDisconnected)
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
            self.finishGuestConnection(generation: generation, error: L.t(.tmTeamPairTimeout))
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
                    self.finishGuestConnection(generation: generation, error: L.t(.tmHostConnectTimeout))
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
