//
//  SavedSession.swift
//  Bonk
//

import Foundation
import SwiftData

/// A saved SSH session configuration for quick reconnect.
@Model
final class SavedSession {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: String
    var credentialID: UUID?
    var groupID: UUID?
    var lastConnectedAt: Date?
    var connectCount: Int
    var isFavorite: Bool
    var sortOrder: Int
    var createdAt: Date

    init(from hostItem: HostItem) {
        self.id = UUID()
        self.name = hostItem.name
        self.host = hostItem.host
        self.port = hostItem.port
        self.username = hostItem.username
        self.authType = hostItem.authTypeRaw
        self.credentialID = hostItem.credentialRef?.keychainID
        self.groupID = hostItem.groupRef?.id
        self.lastConnectedAt = hostItem.lastConnectedAt
        self.connectCount = 0
        self.isFavorite = false
        self.sortOrder = 0
        self.createdAt = Date()
    }

    /// Record a successful connection.
    func recordConnection() {
        lastConnectedAt = Date()
        connectCount += 1
    }
}
