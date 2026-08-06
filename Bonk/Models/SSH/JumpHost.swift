//
//  JumpHost.swift
//  Bonk
//

import Foundation
import SwiftData

/// A jump host (bastion) configuration for multi-hop SSH connections.
@Model
final class JumpHost {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: String
    /// Deprecated — kept for migration, use `credentialRef`.
    var credentialID: UUID?
    @Relationship(deleteRule: .nullify)
    var credentialRef: Credential?
    var sortOrder: Int
    var createdAt: Date

    init(
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authType: String = "password"
    ) {
        id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        sortOrder = 0
        createdAt = Date()
    }

    /// Display string for the jump host.
    var displayString: String {
        "\(username)@\(host):\(port)"
    }
}
