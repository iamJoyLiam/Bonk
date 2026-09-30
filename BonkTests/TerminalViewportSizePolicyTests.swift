//
//  TerminalViewportSizePolicyTests.swift
//  BonkTests
//
//  A PTY has one size. A tab can have several views onto it — the main
//  window's pane view and the Quake panel's view, both rendering the same
//  pane's PTY — and each reports a different size from its own pixel
//  dimensions. These tests pin who is allowed to set that size.
//
//  The policy is a pure function and is tested as one: allow and deny are
//  checked independently of any view, window or PTY, because the decision is
//  where the bug would be cheap to introduce and invisible at runtime.
//

import Foundation
import Testing
@testable import Bonk

// MARK: - The five required cases

@Suite("PTY size authority: focused-wins")
struct TerminalViewportSizePolicyTests {

    private let tabID = UUID()
    private let paneID = UUID()
    private var main: TerminalViewOwner { .pane(paneID) }
    private var quake: TerminalViewOwner { .quakePanel }

    private func size(_ cols: Int, _ rows: Int) -> TerminalViewportSize {
        TerminalViewportSize(cols: cols, rows: rows)
    }

    private func candidate(
        _ owner: TerminalViewOwner,
        visible: Bool = true,
        focused: Bool = false,
        active: Bool = false,
        cols: Int = 120,
        rows: Int = 40
    ) -> TerminalViewportCandidate {
        TerminalViewportCandidate(
            owner: owner,
            isVisible: visible,
            isFocused: focused,
            isActive: active,
            size: size(cols, rows)
        )
    }

    @Test("main focused → main controls the PTY")
    func mainFocusedWins() {
        let decision = TerminalViewportSizePolicy.authority(among: [
            candidate(main, focused: true, active: true, cols: 200, rows: 50),
            candidate(quake, focused: false, cols: 200, rows: 24),
        ])
        #expect(decision?.owner == main)
        #expect(decision?.size == size(200, 50))
    }

    @Test("quake focused → quake controls the PTY")
    func quakeFocusedWins() {
        let decision = TerminalViewportSizePolicy.authority(among: [
            candidate(main, focused: false, active: true, cols: 200, rows: 50),
            candidate(quake, focused: true, cols: 200, rows: 24),
        ])
        #expect(decision?.owner == quake)
        #expect(decision?.size == size(200, 24))
    }

    @Test("quake hidden → main regains control")
    func hidingQuakeRestoresMain() {
        let beforeHide = TerminalViewportSizePolicy.authority(among: [
            candidate(main, active: true, cols: 200, rows: 50),
            candidate(quake, cols: 200, rows: 24),
        ])
        #expect(beforeHide?.owner == main, "precondition: main is the fallback")

        let afterHide = TerminalViewportSizePolicy.authority(among: [
            candidate(main, active: true, cols: 200, rows: 50),
            candidate(quake, visible: false, cols: 200, rows: 24),
        ])
        #expect(afterHide?.owner == main)
        #expect(afterHide?.size == size(200, 50))
    }

    @Test("no focused terminal → main is the fallback, not the panel")
    func noFocusPrefersMainWindow() {
        let decision = TerminalViewportSizePolicy.authority(among: [
            candidate(main, active: true, cols: 200, rows: 50),
            candidate(quake, cols: 200, rows: 24),
        ])
        #expect(decision?.owner == main)
    }

    @Test("two visible owners → exactly one authority")
    func exactlyOneAuthority() {
        // Asserted over a spread of shapes, because "exactly one" is the
        // invariant that matters: a policy returning two winners, or a caller
        // that forwarded both reports, is the original defect.
        let shapes: [[TerminalViewportCandidate]] = [
            [candidate(main), candidate(quake)],
            [candidate(main, focused: true), candidate(quake)],
            [candidate(main), candidate(quake, focused: true)],
            [candidate(main, focused: true), candidate(quake, focused: true)],
            [candidate(.pane(UUID()), active: true), candidate(quake, active: true)],
        ]
        for shape in shapes {
            let decision = TerminalViewportSizePolicy.authority(among: shape)
            #expect(decision != nil, "with eligible views, some view must own the size")
            let eligible = Set(
                shape
                    .filter { $0.isVisible && ($0.size?.isUsable ?? false) }
                    .map(\.owner)
            )
            #expect(
                decision.map { eligible.contains($0.owner) } == true,
                "the authority must be one of the eligible views, not a synthesis"
            )
            // And the size it reports must be that view's own size, so the gate
            // cannot pass a size belonging to the view that lost.
            let owner = decision?.owner
            #expect(
                decision?.size == shape.first { $0.owner == owner }?.size,
                "the authority's size must be its own"
            )
        }

        // No view with a usable size is a different invariant: nobody speaks,
        // rather than a winner being invented. Covered on its own so the two
        // are not conflated.
        #expect(
            TerminalViewportSizePolicy.authority(among: [
                candidate(main, cols: 0, rows: 0), candidate(quake, cols: 0, rows: 0)
            ]) == nil
        )
    }

    // MARK: - Cases the five imply

    @Test("no eligible view → nobody resizes, rather than resizing to nothing")
    func nobodyEligible() {
        #expect(TerminalViewportSizePolicy.authority(among: []) == nil)
        #expect(TerminalViewportSizePolicy.authority(among: [candidate(main, visible: false)]) == nil)
        // A view that has not laid out reports 0x0. That is "no size yet", not
        // a request for a zero-column PTY.
        #expect(TerminalViewportSizePolicy.authority(among: [candidate(main, cols: 0, rows: 0)]) == nil)
    }

    @Test("focus on a view with no size yet falls back instead of blanking the PTY")
    func focusWithoutSizeFallsBack() {
        let decision = TerminalViewportSizePolicy.authority(among: [
            candidate(main, cols: 200, rows: 50),
            candidate(quake, focused: true, cols: 0, rows: 0),
        ])
        #expect(decision?.owner == main)
        #expect(decision?.size == size(200, 50))
    }

    @Test("focus on a hidden view does not win")
    func hiddenFocusDoesNotWin() {
        let decision = TerminalViewportSizePolicy.authority(among: [
            candidate(main, cols: 200, rows: 50),
            candidate(quake, visible: false, focused: true, cols: 200, rows: 24),
        ])
        #expect(decision?.owner == main)
    }

    @Test("the panel is the authority only when it is the sole visible view")
    func panelWinsOnlyAlone() {
        let alone = TerminalViewportSizePolicy.authority(among: [
            candidate(quake, cols: 200, rows: 24),
        ])
        #expect(alone?.owner == quake)

        // The main window's view has not reported a size yet — it just
        // mounted. The panel is the only view that can say anything, so it
        // speaks until the main window has a size to offer.
        let mainNotLaidOut = TerminalViewportSizePolicy.authority(among: [
            candidate(main, cols: 0, rows: 0),
            candidate(quake, cols: 200, rows: 24),
        ])
        #expect(mainNotLaidOut?.owner == quake)
    }

    @Test("linked panes sharing one PTY resolve to the active pane")
    func linkedPanesTieBreakOnActive() {
        let first = UUID()
        let second = UUID()
        let decision = TerminalViewportSizePolicy.authority(among: [
            TerminalViewportCandidate(
                owner: .pane(first), isVisible: true, isFocused: false,
                isActive: false, size: size(80, 24)
            ),
            TerminalViewportCandidate(
                owner: .pane(second), isVisible: true, isFocused: false,
                isActive: true, size: size(100, 30)
            ),
        ])
        #expect(decision?.owner == .pane(second))
    }

    @Test("focus outranks the active pane")
    func focusBeatsActive() {
        let first = UUID()
        let second = UUID()
        let decision = TerminalViewportSizePolicy.authority(among: [
            TerminalViewportCandidate(
                owner: .pane(first), isVisible: true, isFocused: true,
                isActive: false, size: size(80, 24)
            ),
            TerminalViewportCandidate(
                owner: .pane(second), isVisible: true, isFocused: false,
                isActive: true, size: size(100, 30)
            ),
        ])
        #expect(decision?.owner == .pane(first))
    }

    /// The policy's same-rank tiebreak is positional, so the order it is handed
    /// candidates has to be defined rather than incidental.
    @Test("the authority does not depend on the order candidates arrive in")
    func orderIndependent() {
        let a = UUID()
        let b = UUID()
        // Two equally-ranked, equally-active panes: the tiebreak cannot
        // distinguish them, so the supplied order decides. If that order were
        // dictionary order the answer would drift between runs.
        let forward = TerminalViewportSizePolicy.authority(among: [
            TerminalViewportCandidate(owner: .pane(a), isVisible: true, size: size(80, 24)),
            TerminalViewportCandidate(owner: .pane(b), isVisible: true, size: size(80, 24)),
        ])
        let reversed = TerminalViewportSizePolicy.authority(among: [
            TerminalViewportCandidate(owner: .pane(b), isVisible: true, size: size(80, 24)),
            TerminalViewportCandidate(owner: .pane(a), isVisible: true, size: size(80, 24)),
        ])
        #expect(forward?.owner == .pane(a))
        #expect(reversed?.owner == .pane(b), "documented: supplied order breaks a true tie")
    }
}

// MARK: - The gate

@Suite("PTY size authority: the gate")
@MainActor
struct TerminalViewportAuthorityGateTests {

    private func registry() -> TerminalViewportRegistry { TerminalViewportRegistry() }

    @Test("only the authority may resize")
    func onlyAuthorityMayResize() {
        let registry = registry()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)

        registry.register(main, for: key, isVisible: true, isActive: true, size: .init(cols: 200, rows: 50))
        registry.register(.quakePanel, for: key, isVisible: true, size: .init(cols: 200, rows: 24))

        #expect(registry.mayResize(main, in: key))
        #expect(!registry.mayResize(.quakePanel, in: key))

        // Focus moves authority, and only one side is ever allowed.
        registry.setFocused(.quakePanel, in: key)
        #expect(registry.mayResize(.quakePanel, in: key))
        #expect(!registry.mayResize(main, in: key))

        registry.setFocused(main, in: key)
        #expect(registry.mayResize(main, in: key))
        #expect(!registry.mayResize(.quakePanel, in: key))
    }

    @Test("focus is exclusive within a PTY")
    func focusIsExclusive() {
        let registry = registry()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)
        registry.register(main, for: key, isVisible: true, size: .init(cols: 200, rows: 50))
        registry.register(.quakePanel, for: key, isVisible: true, size: .init(cols: 200, rows: 24))

        registry.setFocused(.quakePanel, in: key)
        #expect(registry.candidates(for: key).filter(\.isFocused).map(\.owner) == [.quakePanel])

        registry.setFocused(main, in: key)
        #expect(
            registry.candidates(for: key).filter(\.isFocused).map(\.owner) == [main],
            "focusing the main window's view must withdraw focus from the panel, or both would believe they are the authority"
        )
    }

    /// The transition the user asked for, end to end through the registry.
    @Test("quake open, focus, close → main ends up in control")
    func openFocusCloseRoundTrip() {
        let registry = registry()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)

        // Main window only.
        registry.register(main, for: key, isVisible: true, isActive: true, size: .init(cols: 200, rows: 50))
        #expect(registry.authority(for: key)?.owner == main)

        // Panel opens and takes focus.
        registry.register(.quakePanel, for: key, isVisible: true, size: .init(cols: 200, rows: 24))
        registry.setFocused(.quakePanel, in: key)
        #expect(registry.authority(for: key)?.size == .init(cols: 200, rows: 24))

        // Focus returns to the main window without closing the panel.
        registry.setFocused(main, in: key)
        #expect(registry.authority(for: key)?.size == .init(cols: 200, rows: 50))

        // Panel closes. Its entry must be gone, not merely hidden — a stale
        // visible entry would keep winning.
        registry.unregister(.quakePanel, in: key)
        #expect(registry.authority(for: key)?.owner == main)
        #expect(registry.mayResize(main, in: key))
    }

    @Test("a size report updates the authority's size")
    func sizeReportUpdates() {
        let registry = registry()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)
        registry.register(main, for: key, isVisible: true, size: .init(cols: 80, rows: 24))
        #expect(registry.authority(for: key)?.size == .init(cols: 80, rows: 24))

        registry.setSize(.init(cols: 132, rows: 43), for: main, in: key)
        #expect(registry.authority(for: key)?.size == .init(cols: 132, rows: 43))
    }

    @Test("a report from an unregistered view is ignored")
    func reportFromUnknownOwnerIgnored() {
        let registry = registry()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        // Nothing registered: the registry must not invent an owner.
        registry.setSize(.init(cols: 999, rows: 999), for: .quakePanel, in: key)
        #expect(registry.authority(for: key) == nil)
        #expect(!registry.mayResize(.quakePanel, in: key))
    }

    @Test("two tabs do not share authority")
    func tabsAreIndependent() {
        let registry = registry()
        let paneA = UUID()
        let keyA = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: paneA)
        let keyB = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())

        registry.register(.pane(paneA), for: keyA, isVisible: true, size: .init(cols: 80, rows: 24))
        registry.register(.quakePanel, for: keyA, isVisible: true, size: .init(cols: 80, rows: 10))
        registry.register(.pane(keyB.paneID), for: keyB, isVisible: true, size: .init(cols: 100, rows: 30))

        registry.setFocused(.quakePanel, in: keyA)
        #expect(registry.authority(for: keyA)?.owner == .quakePanel)
        #expect(
            registry.authority(for: keyB)?.owner == .pane(keyB.paneID),
            "focusing the panel on one tab must not take authority on another"
        )
    }

    @Test("unregistering a tab clears every pane's registrations")
    func unregisterAllForTab() {
        let registry = registry()
        let tabID = UUID()
        let keyA = TerminalViewportRegistry.PTYKey(tabID: tabID, paneID: UUID())
        let keyB = TerminalViewportRegistry.PTYKey(tabID: tabID, paneID: UUID())
        registry.register(.pane(keyA.paneID), for: keyA, isVisible: true, size: .init(cols: 80, rows: 24))
        registry.register(.pane(keyB.paneID), for: keyB, isVisible: true, size: .init(cols: 80, rows: 24))

        registry.unregisterAll(forTab: tabID)
        #expect(registry.authority(for: keyA) == nil)
        #expect(registry.authority(for: keyB) == nil)
    }

    /// Candidates come out of a dictionary, and the policy's tiebreak is
    /// positional. This is the test that keeps the two honest.
    @Test("candidates are supplied in a defined order, not dictionary order")
    func candidatesAreOrdered() {
        let registry = registry()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let panes = (0..<5).map { _ in UUID() }
        // Register in an order that is neither the sort key nor the reverse.
        for pane in [panes[3], panes[0], panes[4], panes[1], panes[2]] {
            registry.register(.pane(pane), for: key, isVisible: true, size: .init(cols: 80, rows: 24))
        }
        let keys = registry.candidates(for: key).map(\.owner.stableSortKey)
        #expect(keys == keys.sorted())
    }
}

// MARK: - The transition

/// Focused-wins is two halves, and the second is the one that makes the PTY
/// follow focus.
///
/// The gate stops a non-authority view from resizing. That alone is not enough:
/// a view's report is coalesced and deduplicated upstream, so a view that
/// reported a size while it was not the authority has already had that report
/// absorbed. On promotion nothing re-sends it, and the PTY silently keeps the
/// other view's size — the panel would be authority in name only.
///
/// So a change of authority has to actively resize the PTY to the new owner's
/// size. These tests exercise that through the registry's injected seam, so the
/// transition is verified without a live PTY.
@Suite("PTY size authority: the transition")
@MainActor
struct TerminalViewportAuthorityTransitionTests {

    private struct Recorded {
        let owner: TerminalViewOwner
        let size: TerminalViewportSize
        let key: TerminalViewportRegistry.PTYKey
    }

    /// A registry that records every transition it is asked to perform.
    private func recording() -> (registry: TerminalViewportRegistry, log: () -> [Recorded]) {
        let registry = TerminalViewportRegistry()
        final class Box: @unchecked Sendable { var items: [Recorded] = [] }
        let box = Box()
        registry.onAuthorityChange = { decision, key in
            box.items.append(Recorded(owner: decision.owner, size: decision.size, key: key))
        }
        return (registry, { box.items })
    }

    @Test("focus moving to the panel resizes the PTY to the panel's size")
    func focusTransitionResizes() {
        let (registry, log) = recording()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)

        registry.register(main, for: key, isVisible: true, isActive: true, size: .init(cols: 200, rows: 50))
        registry.register(.quakePanel, for: key, isVisible: true, size: .init(cols: 200, rows: 24))
        let before = log().count

        registry.setFocused(.quakePanel, in: key)
        #expect(log().count == before + 1, "a promotion must resize, not just permit")
        #expect(log().last?.owner == .quakePanel)
        #expect(log().last?.size == .init(cols: 200, rows: 24))
        #expect(log().last?.key == key)

        registry.setFocused(main, in: key)
        #expect(log().last?.owner == main)
        #expect(log().last?.size == .init(cols: 200, rows: 50))
    }

    @Test("closing the panel hands the PTY back to the main window's view")
    func closePanelTransitionsBack() {
        let (registry, log) = recording()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)
        registry.register(main, for: key, isVisible: true, isActive: true, size: .init(cols: 200, rows: 50))
        registry.register(.quakePanel, for: key, isVisible: true, size: .init(cols: 200, rows: 24))
        registry.setFocused(.quakePanel, in: key)
        let before = log().count

        // The panel is torn down, not merely hidden: SwiftUI drops the view.
        registry.unregister(.quakePanel, in: key)
        #expect(log().count == before + 1)
        #expect(log().last?.owner == main, "authority must return to the main window's view")
        #expect(log().last?.size == .init(cols: 200, rows: 50))
    }

    /// Without this the transition would fire on every unrelated keystroke-sized
    /// state change, and each one is an SSH window-change round trip plus a
    /// full repaint of whatever full-screen program is running.
    @Test("no transition when authority does not move")
    func noSpuriousTransitions() {
        let (registry, log) = recording()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)
        registry.register(main, for: key, isVisible: true, isActive: true, size: .init(cols: 200, rows: 50))
        let baseline = log().count

        // The authority reports a new size: still the authority, so nothing to
        // hand over.
        registry.setSize(.init(cols: 180, rows: 45), for: main, in: key)
        #expect(log().count == baseline, "a size change by the authority is not a transition")

        // A non-authority view reports: it is not promoted, so nothing happens.
        registry.register(.quakePanel, for: key, isVisible: true, size: .init(cols: 200, rows: 24))
        let afterRegistration = log().count
        registry.setSize(.init(cols: 210, rows: 26), for: .quakePanel, in: key)
        #expect(log().count == afterRegistration, "a non-authority's report must not resize the PTY")

        // Focus re-asserted on the existing authority.
        registry.setFocused(main, in: key)
        #expect(log().count == afterRegistration)
    }

    /// A view that just mounted has a real size and takes over from one that has
    /// none — the window-opening case, where the previous view has not laid out.
    @Test("a view appearing with a size can take over from one without")
    func appearanceIsATransition() {
        let (registry, log) = recording()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)
        registry.register(main, for: key, isVisible: true, size: .init(cols: 0, rows: 0))
        #expect(registry.authority(for: key) == nil, "precondition: nobody has a size yet")

        let before = log().count
        registry.register(.quakePanel, for: key, isVisible: true, size: .init(cols: 200, rows: 24))
        #expect(log().count == before + 1, "the only view with a size must speak up")
        #expect(log().last?.owner == .quakePanel)
    }

    /// With no eligible view left there is no size to resize to, so the PTY is
    /// left alone rather than being told something arbitrary.
    @Test("losing every view does not resize the PTY")
    func noEligibleViewDoesNotResize() {
        let (registry, log) = recording()
        let key = TerminalViewportRegistry.PTYKey(tabID: UUID(), paneID: UUID())
        let main = TerminalViewOwner.pane(key.paneID)
        registry.register(main, for: key, isVisible: true, size: .init(cols: 200, rows: 50))
        let before = log().count

        registry.unregisterAll(in: key)
        #expect(log().count == before, "nobody to resize to, so no resize")
        #expect(registry.authority(for: key) == nil)
    }
}
