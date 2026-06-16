import SwiftUI

/// Represents one terminal tab — display state only.
/// Connection resources live in TerminalSession.
@Observable @MainActor
final class TerminalTab: Identifiable {
    let id: UUID
    let hostItem: HostItem
    var title: String
    /// Current working directory from terminal title.
    var currentDirectory: String?
    /// Color label for the tab (like macOS Finder labels).
    var colorLabel: String?

    /// Active connection session (nil when disconnected or never connected).
    var session: TerminalSession?

    // MARK: - Display Properties

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
