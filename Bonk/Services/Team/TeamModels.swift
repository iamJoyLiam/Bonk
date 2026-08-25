import Foundation

// MARK: - Team Session

/// Stable routing key for one terminal pane shared with guests.
public struct TeamSessionID: Hashable, Codable, Sendable {
    public let tabID: UUID
    public let paneID: UUID

    public init(tabID: UUID, paneID: UUID) {
        self.tabID = tabID
        self.paneID = paneID
    }
}

// MARK: - Team Protocol

enum TeamProtocolError: Error, Equatable, Sendable {
    case frameTooLarge
    case receiveBufferExceeded
}

/// Newline-delimited frame decoder with explicit memory limits.
struct TeamMessageFramer: Sendable {
    private var buffer = Data()
    private let maxFrameBytes: Int
    private let maxBufferBytes: Int

    init(
        maxFrameBytes: Int = TeamConstants.maxFrameBytes,
        maxBufferBytes: Int = TeamConstants.maxReceiveBufferBytes
    ) {
        self.maxFrameBytes = maxFrameBytes
        self.maxBufferBytes = maxBufferBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= maxBufferBytes else {
            throw TeamProtocolError.receiveBufferExceeded
        }

        var frames: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newlineIndex)
            buffer = Data(buffer.suffix(from: buffer.index(after: newlineIndex)))
            guard line.count <= maxFrameBytes else {
                throw TeamProtocolError.frameTooLarge
            }
            if !line.isEmpty {
                frames.append(Data(line))
            }
        }
        return frames
    }
}

// MARK: - Team Role

enum TeamRole: String, Codable, Sendable, CaseIterable {
    case host
    case guest
    case spectator
}

// MARK: - Team Peer

struct TeamPeer: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var displayName: String
    var role: TeamRole
    var joinedAt: Date
    var isDriver: Bool

    init(id: UUID = UUID(), displayName: String, role: TeamRole, joinedAt: Date = Date(), isDriver: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.joinedAt = joinedAt
        self.isDriver = isDriver
    }
}

// MARK: - Team Presence Snapshot

struct TeamPresenceSnapshot: Codable, Sendable, Equatable {
    var hostPeer: TeamPeer
    var guestPeers: [TeamPeer]
    var driverPeerID: UUID?
    var sharedSessionID: TeamSessionID?

    var allPeers: [TeamPeer] { [hostPeer] + guestPeers }

    init(
        hostPeer: TeamPeer,
        guestPeers: [TeamPeer],
        driverPeerID: UUID?,
        sharedSessionID: TeamSessionID? = nil
    ) {
        self.hostPeer = hostPeer
        self.guestPeers = guestPeers
        self.driverPeerID = driverPeerID
        self.sharedSessionID = sharedSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case hostPeer, guestPeers, driverPeerID, sharedSessionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostPeer = try container.decode(TeamPeer.self, forKey: .hostPeer)
        guestPeers = try container.decode([TeamPeer].self, forKey: .guestPeers)
        driverPeerID = try container.decodeIfPresent(UUID.self, forKey: .driverPeerID)
        sharedSessionID = try container.decodeIfPresent(TeamSessionID.self, forKey: .sharedSessionID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostPeer, forKey: .hostPeer)
        try container.encode(guestPeers, forKey: .guestPeers)
        try container.encodeIfPresent(driverPeerID, forKey: .driverPeerID)
        try container.encodeIfPresent(sharedSessionID, forKey: .sharedSessionID)
    }
}

// MARK: - Team Message (framed JSON over NWConnection)

enum TeamMessage: Codable, Sendable, Equatable {
    // PTY
    case terminalOutput(sessionID: TeamSessionID, payload: String) // raw terminal bytes encoded as UTF-8
    case terminalInput(sessionID: TeamSessionID, payload: String)
    case resize(sessionID: TeamSessionID, columns: Int, rows: Int)
    // Control
    case controlRequest(peerID: UUID, displayName: String)
    case controlGrant(peerID: UUID)
    case controlRevoke(peerID: UUID)
    // Presence
    case presenceSnapshot(snapshot: TeamPresenceSnapshot)
    case peerJoined(peer: TeamPeer)
    case peerLeft(peerID: UUID)
    // System
    case notice(payload: String)
    case heartbeat
    case pairingChallenge(pin: String, peer: TeamPeer)
    case pairingRejected(reason: String)

    private enum CodingKeys: String, CodingKey {
        case type, payload, sessionID, columns, rows, peerID, displayName, snapshot, peer, pin, reason
    }
    private enum MessageType: String, Codable {
        case terminalOutput, terminalInput, resize
        case controlRequest, controlGrant, controlRevoke
        case presenceSnapshot, peerJoined, peerLeft
        case notice, heartbeat, pairingChallenge, pairingRejected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .terminalOutput:
            self = .terminalOutput(
                sessionID: try container.decode(TeamSessionID.self, forKey: .sessionID),
                payload: try container.decode(String.self, forKey: .payload)
            )
        case .terminalInput:
            self = .terminalInput(
                sessionID: try container.decode(TeamSessionID.self, forKey: .sessionID),
                payload: try container.decode(String.self, forKey: .payload)
            )
        case .resize:
            self = .resize(
                sessionID: try container.decode(TeamSessionID.self, forKey: .sessionID),
                columns: try container.decode(Int.self, forKey: .columns),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case .controlRequest: self = .controlRequest(peerID: try container.decode(UUID.self, forKey: .peerID), displayName: try container.decode(String.self, forKey: .displayName))
        case .controlGrant: self = .controlGrant(peerID: try container.decode(UUID.self, forKey: .peerID))
        case .controlRevoke: self = .controlRevoke(peerID: try container.decode(UUID.self, forKey: .peerID))
        case .presenceSnapshot: self = .presenceSnapshot(snapshot: try container.decode(TeamPresenceSnapshot.self, forKey: .snapshot))
        case .peerJoined: self = .peerJoined(peer: try container.decode(TeamPeer.self, forKey: .peer))
        case .peerLeft: self = .peerLeft(peerID: try container.decode(UUID.self, forKey: .peerID))
        case .notice: self = .notice(payload: try container.decode(String.self, forKey: .payload))
        case .heartbeat: self = .heartbeat
        case .pairingChallenge:
            let peer = try container.decodeIfPresent(TeamPeer.self, forKey: .peer)
                ?? TeamPeer(displayName: "Guest", role: .guest)
            self = .pairingChallenge(
                pin: try container.decode(String.self, forKey: .pin),
                peer: peer
            )
        case .pairingRejected:
            self = .pairingRejected(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .terminalOutput(sessionID, payload):
            try container.encode(MessageType.terminalOutput, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(payload, forKey: .payload)
        case let .terminalInput(sessionID, payload):
            try container.encode(MessageType.terminalInput, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(payload, forKey: .payload)
        case let .resize(sessionID, columns, rows):
            try container.encode(MessageType.resize, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(columns, forKey: .columns)
            try container.encode(rows, forKey: .rows)
        case let .controlRequest(peerID, displayName):
            try container.encode(MessageType.controlRequest, forKey: .type); try container.encode(peerID, forKey: .peerID); try container.encode(displayName, forKey: .displayName)
        case let .controlGrant(peerID):
            try container.encode(MessageType.controlGrant, forKey: .type); try container.encode(peerID, forKey: .peerID)
        case let .controlRevoke(peerID):
            try container.encode(MessageType.controlRevoke, forKey: .type); try container.encode(peerID, forKey: .peerID)
        case let .presenceSnapshot(snapshot):
            try container.encode(MessageType.presenceSnapshot, forKey: .type); try container.encode(snapshot, forKey: .snapshot)
        case let .peerJoined(peer):
            try container.encode(MessageType.peerJoined, forKey: .type); try container.encode(peer, forKey: .peer)
        case let .peerLeft(peerID):
            try container.encode(MessageType.peerLeft, forKey: .type); try container.encode(peerID, forKey: .peerID)
        case let .notice(payload):
            try container.encode(MessageType.notice, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .heartbeat:
            try container.encode(MessageType.heartbeat, forKey: .type)
        case let .pairingChallenge(pin, peer):
            try container.encode(MessageType.pairingChallenge, forKey: .type)
            try container.encode(pin, forKey: .pin)
            try container.encode(peer, forKey: .peer)
        case let .pairingRejected(reason):
            try container.encode(MessageType.pairingRejected, forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - Team Constants

enum TeamConstants {
    static let serviceType = "_bonk-team._tcp"
    static let serviceDomain = "local."
    static let defaultHostName = "BonkHost"
    static let pairingPinLength = 6
    static let replayBufferLineLimit = 10_000
    static let replayBufferByteLimit = 2 * 1024 * 1024
    static let heartbeatIntervalSeconds: TimeInterval = 15
    static let connectionTimeoutSeconds: TimeInterval = 8
    static let maxGuestCount = 1 // MVP: 1 host + 1 guest
    static let maxFrameBytes = 256 * 1024
    static let maxReceiveBufferBytes = 512 * 1024
    static let maxPairingFailuresPerMinute = 5
}
