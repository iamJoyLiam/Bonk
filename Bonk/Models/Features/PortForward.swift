//
//  PortForward.swift
//  Bonk
//

import Foundation
import SwiftData

/// A port forwarding rule.
@Model
final class PortForward {
    var id: UUID
    var name: String
    var typeRaw: String
    var localHost: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
    var isActive: Bool
    var createdAt: Date

    enum ForwardType: String, CaseIterable {
        case local
        case remote
        case dynamic

        var displayName: String {
            switch self {
            case .local: "Local (-L)"
            case .remote: "Remote (-R)"
            case .dynamic: "Dynamic (-D)"
            }
        }
    }

    var type: ForwardType {
        get { ForwardType(rawValue: typeRaw) ?? .local }
        set { typeRaw = newValue.rawValue }
    }

    init(
        name: String,
        type: ForwardType = .local,
        localHost: String = "127.0.0.1",
        localPort: Int,
        remoteHost: String = "127.0.0.1",
        remotePort: Int
    ) {
        id = UUID()
        self.name = name
        typeRaw = type.rawValue
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        isActive = false
        createdAt = Date()
    }

    var displayDescription: String {
        switch type {
        case .local:
            "\(localHost):\(localPort) → \(remoteHost):\(remotePort)"
        case .remote:
            "\(remoteHost):\(remotePort) → \(localHost):\(localPort)"
        case .dynamic:
            "SOCKS5 \(localHost):\(localPort)"
        }
    }
}
