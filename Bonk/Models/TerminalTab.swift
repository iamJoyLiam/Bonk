import Foundation
import SwiftUI

/// Represents one terminal tab / SSH session.
@Observable @MainActor
final class TerminalTab: Identifiable {
    let id: UUID
    let hostItem: HostItem
    var connectionState: SSHConnectionState = .disconnected
    var outputStream: AsyncStream<String>?
    var sshService: SSHNetworkService?
    var ptySession: PTYSession?
    var title: String
    /// Current working directory from terminal title.
    var currentDirectory: String?
    var connectedAt: Date?
    var errorMessage: String?
    var stateObservationTask: Task<Void, Never>?
    /// SFTP service for this tab (lazy, created on first use).
    var sftpService: SFTPService?
    /// Server system info (fetched after connection).
    var serverInfo: ServerInfo?
    /// Timer for refreshing server info.
    var serverInfoTask: Task<Void, Never>?
    /// Color label for the tab (like macOS Finder labels).
    var colorLabel: String?

    /// Available color labels.
    static let colorLabels: [(name: String, color: Color)] = [
        ("red", .red),
        ("orange", .orange),
        ("yellow", .yellow),
        ("green", .green),
        ("blue", .blue),
        ("purple", .purple),
        ("pink", .pink),
    ]

    /// Resolve the color label to a SwiftUI Color.
    var resolvedColor: Color? {
        guard let colorLabel else { return nil }
        return Self.colorLabels.first(where: { $0.name == colorLabel })?.color
    }

    init(hostItem: HostItem) {
        id = UUID()
        self.hostItem = hostItem
        title = hostItem.name
    }
}
