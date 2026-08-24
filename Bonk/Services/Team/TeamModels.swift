import Foundation

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

struct TeamPresenceSnapshot: Codable, Sendable {
    var hostPeer: TeamPeer
    var guestPeers: [TeamPeer]
    var driverPeerID: UUID?

    var allPeers: [TeamPeer] { [hostPeer] + guestPeers }
}

// MARK: - Team Message (framed JSON over NWConnection)

enum TeamMessage: Codable, Sendable {
    // PTY
    case terminalOutput(payload: String) // base64 or raw string chunk
    case terminalInput(payload: String)
    case resize(columns: Int, rows: Int)
    // Control
    case controlRequest(peerID: UUID, displayName: String)
    case controlGrant(peerID: UUID)
    case controlRevoke(peerID: UUID)
    // Presence
    case presenceSnapshot(snapshot: TeamPresenceSnapshot)
    case peerJoined(peer: TeamPeer)
    case peerLeft(peerID: UUID)
    // System
    case heartbeat
    case pairingChallenge(pin: String)

    private enum CodingKeys: String, CodingKey {
        case type, payload, columns, rows, peerID, displayName, snapshot, peer, pin
    }
    private enum MessageType: String, Codable {
        case terminalOutput, terminalInput, resize
        case controlRequest, controlGrant, controlRevoke
        case presenceSnapshot, peerJoined, peerLeft
        case heartbeat, pairingChallenge
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .terminalOutput: self = .terminalOutput(payload: try container.decode(String.self, forKey: .payload))
        case .terminalInput: self = .terminalInput(payload: try container.decode(String.self, forKey: .payload))
        case .resize: self = .resize(columns: try container.decode(Int.self, forKey: .columns), rows: try container.decode(Int.self, forKey: .rows))
        case .controlRequest: self = .controlRequest(peerID: try container.decode(UUID.self, forKey: .peerID), displayName: try container.decode(String.self, forKey: .displayName))
        case .controlGrant: self = .controlGrant(peerID: try container.decode(UUID.self, forKey: .peerID))
        case .controlRevoke: self = .controlRevoke(peerID: try container.decode(UUID.self, forKey: .peerID))
        case .presenceSnapshot: self = .presenceSnapshot(snapshot: try container.decode(TeamPresenceSnapshot.self, forKey: .snapshot))
        case .peerJoined: self = .peerJoined(peer: try container.decode(TeamPeer.self, forKey: .peer))
        case .peerLeft: self = .peerLeft(peerID: try container.decode(UUID.self, forKey: .peerID))
        case .heartbeat: self = .heartbeat
        case .pairingChallenge: self = .pairingChallenge(pin: try container.decode(String.self, forKey: .pin))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .terminalOutput(payload):
            try container.encode(MessageType.terminalOutput, forKey: .type); try container.encode(payload, forKey: .payload)
        case let .terminalInput(payload):
            try container.encode(MessageType.terminalInput, forKey: .type); try container.encode(payload, forKey: .payload)
        case let .resize(columns, rows):
            try container.encode(MessageType.resize, forKey: .type); try container.encode(columns, forKey: .columns); try container.encode(rows, forKey: .rows)
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
        case .heartbeat:
            try container.encode(MessageType.heartbeat, forKey: .type)
        case let .pairingChallenge(pin):
            try container.encode(MessageType.pairingChallenge, forKey: .type); try container.encode(pin, forKey: .pin)
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
}
