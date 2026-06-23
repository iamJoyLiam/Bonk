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

    /// Source tab hostItem for unsplit (preserves original hostItem after drag-to-split)
    var sourceHostItem: HostItem?

    /// Active connection session (nil when disconnected or never connected).
    var session: TerminalSession?

    /// Split pane layout within this tab.
    /// Starts as a single pane, can be split into multiple panes.
    var layout: TabLayout

    /// Currently active (focused) pane ID.
    var activePaneID: UUID?

    /// Whether local broadcast is enabled (all panes in this tab receive input).
    var isBroadcastEnabled: Bool = false

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

/// Session binding mode for a pane.
enum SessionMode: Equatable {
    /// Independent PTY session (default).
    case independent
    /// Linked to another pane's PTY session (shared view).
    case linked(sourcePaneID: UUID)
}

/// Represents a single pane's state within a tab.
@Observable @MainActor
final class PaneState: Identifiable {
    let id: UUID
    /// The PTY session for this pane.
    var ptySession: PTYSession?
    /// Session binding mode.
    var sessionMode: SessionMode = .independent
    /// Display title for this pane.
    var title: String = ""

    init() {
        id = UUID()
    }

    /// The effective PTY session (own or linked source).
    func effectivePTY(allPanes: [PaneState]) -> PTYSession? {
        switch sessionMode {
        case .independent:
            return ptySession
        case .linked(let sourceID):
            return allPanes.first(where: { $0.id == sourceID })?.ptySession ?? ptySession
        }
    }
}
