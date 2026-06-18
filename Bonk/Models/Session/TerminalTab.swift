import SwiftUI

/// Represents one terminal tab — a workspace that can contain multiple panes.
@Observable @MainActor
final class TerminalTab: Identifiable {
    let id: UUID
    let hostItem: HostItem
    var title: String
    var currentDirectory: String?
    var colorLabel: String?
    var pendingRestore = false

    /// Active connection session (nil when disconnected or never connected).
    var session: TerminalSession?

    /// Split pane layout within this tab.
    /// Starts as a single pane, can be split into multiple panes.
    var layout: TabLayout

    /// Currently active (focused) pane ID.
    var activePaneID: UUID

    /// All pane IDs in this tab.
    var paneIDs: [UUID] {
        layout.root.allPaneIDs
    }

    // MARK: - Display Properties

    static let colorLabels: [(name: String, color: Color)] = [
        ("red", .red),
        ("orange", .orange),
        ("yellow", .yellow),
        ("green", .green),
        ("blue", .blue),
        ("purple", .purple),
        ("pink", .pink),
    ]

    var resolvedColor: Color? {
        guard let colorLabel else { return nil }
        return Self.colorLabels.first(where: { $0.name == colorLabel })?.color
    }

    init(hostItem: HostItem) {
        id = UUID()
        self.hostItem = hostItem
        title = hostItem.name
        let pane = PaneState()
        layout = TabLayout(root: .pane(pane))
        activePaneID = pane.id
    }
}

/// Represents a single pane's state within a tab.
@Observable @MainActor
final class PaneState: Identifiable {
    let id: UUID
    /// The PTY session for this pane (independent terminal instance).
    var ptySession: PTYSession?
    /// Whether this pane is currently active (focused).
    var isActive: Bool = false
    /// Display title for this pane (e.g., working directory or custom name).
    var title: String = ""

    init() {
        id = UUID()
    }
}
