//
//  TerminalViewportRegistry.swift
//  Bonk
//
//  Which terminal view currently owns each PTY's size, and the gate every
//  view-driven resize passes through.
//
//  The registry holds the reported state — who is mounted, who has focus, who
//  is active, what size each has last reported — and asks
//  `TerminalViewportSizePolicy` who the authority is. It decides nothing
//  itself. `SessionManager.resizePTY` consults `mayResize` before touching a
//  PTY, so a non-authority view's report is dropped rather than racing the
//  authority's.
//
//  Keyed by PTY, not by tab: a tab's PTY belongs to a pane, and in linked mode
//  two panes share one. `.pane(id)` views register under their own pane;
//  `.quakePanel` and `.mainWindow` register under the tab's active pane, which
//  is the PTY they render.
//

import Foundation
import os.log

@MainActor
final class TerminalViewportRegistry {
    static let shared = TerminalViewportRegistry()

    /// The PTY a set of views shares.
    struct PTYKey: Hashable, Sendable {
        let tabID: UUID
        let paneID: UUID
    }

    private struct Registration {
        var owner: TerminalViewOwner
        var isVisible: Bool
        var isFocused: Bool
        var isActive: Bool
        var size: TerminalViewportSize?
    }

    private let logger = Logger(subsystem: "com.bonk", category: "Viewport")
    private var registrations: [PTYKey: [TerminalViewOwner: Registration]] = [:]

    /// Called when a PTY's authority changes, so the PTY can be resized to the
    /// new owner's size.
    ///
    /// This is the transition half of focused-wins, and it is not optional
    /// bookkeeping. A view's own resize is coalesced and deduplicated upstream,
    /// so a view that reported a size while it was *not* the authority has
    /// already had that report absorbed: when it later becomes the authority,
    /// nothing re-sends it and the PTY keeps the other view's size. Gating alone
    /// would leave the PTY sized for a view the user is no longer looking at.
    ///
    /// Injected rather than called directly, so the registry holds no session
    /// state and the transition is testable without a PTY.
    var onAuthorityChange: ((TerminalViewportAuthority, PTYKey) -> Void)?

    /// Internal rather than private so tests can exercise a registry of their
    /// own. Production code goes through `shared`; a test that used the shared
    /// instance would be asserting on residue from whatever ran before it.
    init() {}

    // MARK: - Transition

    /// Re-evaluate a PTY's authority and, if it moved, report the new owner.
    ///
    /// Every mutation goes through this, because any of them can move authority:
    /// a focus change obviously, but so can a view appearing with a size, a view
    /// reporting one for the first time, or a view going away.
    private func authorityDidChange(for key: PTYKey, from previous: TerminalViewportAuthority?) {
        let current = authority(for: key)
        guard previous?.owner != current?.owner else { return }
        logger.info(
            "[PTY] size authority: \(previous?.owner.stableSortKey ?? "none", privacy: .public) -> \(current?.owner.stableSortKey ?? "none", privacy: .public) size=\(current?.size.cols ?? 0, privacy: .public)x\(current?.size.rows ?? 0, privacy: .public)"
        )
        // Nobody winning is not a transition to apply: there is no size to
        // resize to, and the PTY should keep what it has.
        if let current { onAuthorityChange?(current, key) }
    }

    // MARK: - Registration

    /// Declare a view onto `key`'s PTY. Safe to call repeatedly with the full
    /// state; mount sites call it from `updateNSView`, which SwiftUI runs far
    /// more often than the state changes.
    func register(
        _ owner: TerminalViewOwner,
        for key: PTYKey,
        isVisible: Bool,
        isFocused: Bool? = nil,
        isActive: Bool = false,
        size: TerminalViewportSize? = nil
    ) {
        let before = authority(for: key)
        defer { authorityDidChange(for: key, from: before) }
        var table = registrations[key] ?? [:]
        var entry = table[owner] ?? Registration(
            owner: owner, isVisible: isVisible,
            isFocused: false, isActive: isActive, size: size
        )
        entry.isVisible = isVisible
        entry.isActive = isActive
        if let size { entry.size = size }
        // `nil` means "not stated", so an update that does not talk about focus
        // leaves the existing focus alone. Focus is owned by the focus observer.
        if let isFocused { entry.isFocused = isFocused }
        table[owner] = entry
        registrations[key] = table
    }

    /// A view's latest physical size.
    func setSize(_ size: TerminalViewportSize, for owner: TerminalViewOwner, in key: PTYKey) {
        let before = authority(for: key)
        defer { authorityDidChange(for: key, from: before) }
        guard var table = registrations[key], var entry = table[owner] else { return }
        entry.size = size
        table[owner] = entry
        registrations[key] = table
    }

    func setVisible(_ isVisible: Bool, for owner: TerminalViewOwner, in key: PTYKey) {
        let before = authority(for: key)
        defer { authorityDidChange(for: key, from: before) }
        guard var table = registrations[key], var entry = table[owner] else { return }
        entry.isVisible = isVisible
        table[owner] = entry
        registrations[key] = table
    }

    /// Move focus to `owner`, or clear it with `nil`.
    ///
    /// Focus is exclusive within a PTY: focusing the Quake view withdraws it
    /// from the main window's view of the same PTY, which is what makes
    /// focused-wins a transition rather than two winners.
    func setFocused(_ owner: TerminalViewOwner?, in key: PTYKey) {
        let before = authority(for: key)
        defer { authorityDidChange(for: key, from: before) }
        guard var table = registrations[key] else { return }
        for (existing, var entry) in table where entry.isFocused {
            entry.isFocused = false
            table[existing] = entry
        }
        if let owner, var entry = table[owner] {
            entry.isFocused = true
            table[owner] = entry
        }
        registrations[key] = table
    }

    // MARK: - Removal

    /// A view went away. Its entry must not linger: a stale `isVisible: true`
    /// would keep owning the PTY after unmount.
    func unregister(_ owner: TerminalViewOwner, in key: PTYKey) {
        let before = authority(for: key)
        defer { authorityDidChange(for: key, from: before) }
        registrations[key]?.removeValue(forKey: owner)
        if registrations[key]?.isEmpty == true { registrations[key] = nil }
    }

    func unregisterAll(in key: PTYKey) {
        let before = authority(for: key)
        defer { authorityDidChange(for: key, from: before) }
        registrations[key] = nil
    }

    /// Every owner registered against `tabID`, in any of its panes.
    func unregisterAll(forTab tabID: UUID) {
        let befores = registrations
            .filter { $0.key.tabID == tabID }
            .map { ($0.key, authority(for: $0.key)) }
        defer { for (key, before) in befores { authorityDidChange(for: key, from: before) } }
        for key in registrations.keys where key.tabID == tabID {
            registrations[key] = nil
        }
    }

    // MARK: - Decisions

    /// The views onto `key`'s PTY, in a defined order.
    ///
    /// Sorted by `stableSortKey` because the policy's same-rank tiebreak is
    /// positional, and dictionary order would make the authority depend on
    /// insertion history.
    func candidates(for key: PTYKey) -> [TerminalViewportCandidate] {
        (registrations[key] ?? [:])
            .values
            .map {
                TerminalViewportCandidate(
                    owner: $0.owner,
                    isVisible: $0.isVisible,
                    isFocused: $0.isFocused,
                    isActive: $0.isActive,
                    size: $0.size
                )
            }
            .sorted { $0.owner.stableSortKey < $1.owner.stableSortKey }
    }

    func authority(for key: PTYKey) -> TerminalViewportAuthority? {
        TerminalViewportSizePolicy.authority(among: candidates(for: key))
    }

    /// The gate. `true` only for the view that currently owns the PTY's size.
    func mayResize(_ owner: TerminalViewOwner, in key: PTYKey) -> Bool {
        TerminalViewportSizePolicy.mayResize(owner, among: candidates(for: key))
    }
}
