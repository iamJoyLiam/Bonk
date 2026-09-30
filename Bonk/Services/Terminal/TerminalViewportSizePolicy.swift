//
//  TerminalViewportSizePolicy.swift
//  Bonk
//
//  Which terminal view owns the size of a PTY that more than one view is
//  rendering.
//
//  A tab's PTY has one size. A tab can have several views onto it: the main
//  window's pane view, the Quake panel's view, and — in linked mode — a
//  second pane view sharing the same PTY. Each view has its own pixel size,
//  hence its own column and row count, and each reports its own resize. If
//  every report is forwarded, the last one to lay out wins and the views
//  disagree with the PTY, so full-screen programs (vim, top, less) render
//  clipped, wrapped or misaligned in whichever view is not the current winner.
//
//  So the PTY's size is owned by exactly one view at a time, and this file
//  decides which. It is a pure function of the views' reported state: no
//  AppKit, no session, no clock. `TerminalViewportRegistry` holds the state
//  and applies the result; nothing else decides.
//

import Foundation

// MARK: - Reported state

/// A terminal view's grid, as reported by its physical layout.
struct TerminalViewportSize: Equatable, Sendable {
    let cols: Int
    let rows: Int

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// A view that has not laid out yet reports `0x0`.
    ///
    /// That means "no size yet", not "make the PTY zero columns wide". Only a
    /// usable size may become the authority's, so a freshly mounted view cannot
    /// blank the terminal.
    var isUsable: Bool { cols > 0 && rows > 0 }
}

/// One view onto a PTY, as the policy sees it.
struct TerminalViewportCandidate: Equatable, Sendable {
    let owner: TerminalViewOwner
    /// The view is mounted and on screen. A hidden Quake panel is not a
    /// candidate even though its view may still exist.
    let isVisible: Bool
    /// The view holds keyboard focus.
    let isFocused: Bool
    /// The view's pane is the tab's active pane. Only a tiebreak: it never
    /// outranks focus.
    let isActive: Bool
    /// The view's last reported size, or `nil` if it has not laid out.
    let size: TerminalViewportSize?

    init(
        owner: TerminalViewOwner,
        isVisible: Bool,
        isFocused: Bool = false,
        isActive: Bool = false,
        size: TerminalViewportSize?
    ) {
        self.owner = owner
        self.isVisible = isVisible
        self.isFocused = isFocused
        self.isActive = isActive
        self.size = size
    }
}

/// The single view permitted to set a PTY's size, and the size it wants.
struct TerminalViewportAuthority: Equatable, Sendable {
    let owner: TerminalViewOwner
    let size: TerminalViewportSize
}

// MARK: - Policy

enum TerminalViewportSizePolicy {

    /// The one view whose size the PTY takes.
    ///
    /// Precedence, highest first:
    ///
    /// 1. **The focused view.** Focused-wins: whoever is typing owns the size.
    ///    This is the whole point — a user who has clicked into the Quake panel
    ///    and opened `vim` needs the panel to be the authority, or the panel
    ///    renders a screen laid out for a window they are no longer looking at.
    /// 2. **A main-window view.** With no focused terminal, the main window is
    ///    the durable view; the Quake panel is transient. Note this is a
    ///    property of the owner *kind*, not of the literal `.mainWindow` case:
    ///    on macOS the main window's view is `.pane(UUID)` and `.mainWindow` is
    ///    only ever constructed on the iOS path.
    /// 3. **The Quake panel.** Only reached when it is the sole visible view —
    ///    for instance while the panel is up and the main window's view for that
    ///    PTY has not reported a size yet.
    ///
    /// Ties within a rank break on `isActive`, then on the order candidates
    /// were supplied, so the result never depends on dictionary or set ordering.
    /// Linked mode makes real ties possible: two pane views share one PTY.
    ///
    /// - Returns: `nil` when no visible view has a usable size. That is "leave
    ///   the PTY alone" — not "resize to nothing".
    static func authority(
        among candidates: [TerminalViewportCandidate]
    ) -> TerminalViewportAuthority? {
        let eligible = candidates.filter { $0.isVisible && ($0.size?.isUsable ?? false) }
        guard !eligible.isEmpty else { return nil }

        if let winner = pickFrom(eligible, where: { $0.isFocused }) {
            return winner
        }
        if let winner = pickFrom(eligible, where: { !$0.owner.isQuakePanel }) {
            return winner
        }
        return pickFrom(eligible, where: { _ in true })
    }

    /// Whether `owner` is the view allowed to resize right now.
    ///
    /// This is the gate the resize path asks. Keeping it here rather than in the
    /// caller means the allow and deny decisions cannot disagree.
    static func mayResize(
        _ owner: TerminalViewOwner,
        among candidates: [TerminalViewportCandidate]
    ) -> Bool {
        authority(among: candidates)?.owner == owner
    }

    private static func pickFrom(
        _ candidates: [TerminalViewportCandidate],
        where predicate: (TerminalViewportCandidate) -> Bool
    ) -> TerminalViewportAuthority? {
        // First active, else first supplied. Not `sorted`: Swift's sort is not
        // stable, so an equal-elements comparator would make the winner depend
        // on unspecified ordering — which is the class of bug this policy
        // exists to remove.
        let pool = candidates.filter(predicate)
        guard let best = pool.first(where: \.isActive) ?? pool.first,
              let size = best.size
        else { return nil }
        return TerminalViewportAuthority(owner: best.owner, size: size)
    }
}

// MARK: - Owner classification

extension TerminalViewOwner {
    /// The Quake panel: a transient second view of a PTY another view is
    /// already rendering.
    var isQuakePanel: Bool {
        if case .quakePanel = self { return true }
        return false
    }

    /// A total order over owners, so the candidates handed to the policy are in
    /// a defined sequence.
    ///
    /// The policy breaks same-rank ties on the order it was given, which is only
    /// meaningful if that order is not whatever a dictionary iteration happened
    /// to produce. Main-window views sort before the Quake panel, and panes
    /// order by id, so the same set of views always yields the same authority.
    var stableSortKey: String {
        switch self {
        case .mainWindow: "0:mainWindow"
        case .pane(let id): "1:pane:\(id.uuidString)"
        case .quakePanel: "2:quakePanel"
        }
    }
}
