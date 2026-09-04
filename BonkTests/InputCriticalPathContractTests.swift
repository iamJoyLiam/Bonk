//
//  InputCriticalPathContractTests.swift
//  BonkTests
//
//  Tests validating P0.1 Input Critical Path & P0.2 Overlay Lifecycle Contracts.
//

import AppKit
import Testing
@testable import Bonk

@Suite("P0.1 & P0.2 Input Critical Path and Overlay Lifecycle Contracts")
@MainActor
struct InputCriticalPathContractTests {

    private func makeTerminalWithCandidates() -> (NativeTerminalView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), font: font)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        let cache = InlineSuggestionCache()
        let pipeline = InlineSuggestionPipeline(providerStore: .shared, cache: cache)
        view.inlinePipeline = pipeline

        let snapshot = CommandContextSnapshot(
            inputBuffer: "dock",
            recentCommands: ["docker ps", "docker build -t app .", "docker run -d nginx"],
            recentOutput: ""
        )
        pipeline.request(snapshot: snapshot)
        return (view, window)
    }

    private func makeKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "", window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    // MARK: - Contract 1: Critical Path Key Handling & Zero Hijacking

    @Test("1. Passive mode: Enter passes 100% through to Shell without hijacking")
    func testPassiveEnterPassesThrough() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        #expect(pipeline.suggestion != nil)
        #expect(pipeline.engagement == .passive)

        // Enter key (36)
        let enterEvent = makeKeyEvent(keyCode: 36, characters: "\r", window: window)
        let result = view.processKeyEvent(enterEvent)

        // Must return the event to forward to shell, NOT nil (consumed)
        #expect(result === enterEvent)
        // Suggestion must be dismissed
        #expect(pipeline.suggestion == nil)
    }

    @Test("2. Passive mode: Up / Down arrow passes 100% through to Shell for history navigation")
    func testPassiveArrowKeysPassThrough() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        #expect(pipeline.suggestion != nil)
        #expect(pipeline.engagement == .passive)

        // Up arrow (126)
        let upEvent = makeKeyEvent(keyCode: 126, window: window)
        let upResult = view.processKeyEvent(upEvent)
        #expect(upResult === upEvent)

        // Down arrow (125)
        let downEvent = makeKeyEvent(keyCode: 125, window: window)
        let downResult = view.processKeyEvent(downEvent)
        #expect(downResult === downEvent)
    }

    @Test("3. Passive mode: Tab accepts top recommendation")
    func testPassiveTabAccepts() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        #expect(pipeline.suggestion != nil)
        #expect(pipeline.engagement == .passive)

        // Tab key (48)
        let tabEvent = makeKeyEvent(keyCode: 48, characters: "\t", window: window)
        let result = view.processKeyEvent(tabEvent)

        // Consumed (returns nil) to accept
        #expect(result == nil)
        #expect(pipeline.suggestion == nil)
    }

    @Test("4. Passive mode: Esc dismisses suggestion without forwarding")
    func testPassiveEscDismisses() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        #expect(pipeline.suggestion != nil)

        // Esc key (53)
        let escEvent = makeKeyEvent(keyCode: 53, window: window)
        let result = view.processKeyEvent(escEvent)

        // Consumed (returns nil)
        #expect(result == nil)
        #expect(pipeline.suggestion == nil)
    }

    @Test("5. Option+Down engages candidate selection")
    func testOptionDownEngagesSelection() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        UserDefaults.standard.set(true, forKey: "ai_inline_candidate_popup")
        defer { UserDefaults.standard.removeObject(forKey: "ai_inline_candidate_popup") }

        #expect(pipeline.engagement == .passive)

        // Option+Down (125, .option)
        let optDownEvent = makeKeyEvent(keyCode: 125, modifiers: .option, window: window)
        let result = view.processKeyEvent(optDownEvent)

        #expect(result == nil)
        #expect(pipeline.engagement.isEngaged)
        #expect(pipeline.selectedIndex == 0)
    }

    @Test("6. Engaged mode: Up / Down navigates candidate list")
    func testEngagedArrowNavigatesCandidates() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        UserDefaults.standard.set(true, forKey: "ai_inline_candidate_popup")
        defer { UserDefaults.standard.removeObject(forKey: "ai_inline_candidate_popup") }

        // Engage selection at 0
        pipeline.moveSelection(1)
        #expect(pipeline.selectedIndex == 0)

        // Down arrow (125) moves to index 1
        let downEvent = makeKeyEvent(keyCode: 125, window: window)
        let downResult = view.processKeyEvent(downEvent)
        #expect(downResult == nil)
        #expect(pipeline.selectedIndex == 1)

        // Up arrow (126) moves back to index 0
        let upEvent = makeKeyEvent(keyCode: 126, window: window)
        let upResult = view.processKeyEvent(upEvent)
        #expect(upResult == nil)
        #expect(pipeline.selectedIndex == 0)
    }

    @Test("7. Engaged mode: Enter accepts the currently selected candidate")
    func testEngagedEnterAcceptsCandidate() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        // Engage selection at 1
        pipeline.moveSelection(1)
        pipeline.moveSelection(1)
        #expect(pipeline.selectedIndex == 1)

        // Enter key (36) accepts
        let enterEvent = makeKeyEvent(keyCode: 36, characters: "\r", window: window)
        let result = view.processKeyEvent(enterEvent)

        #expect(result == nil)
        #expect(pipeline.suggestion == nil)
    }

    @Test("8. Typing and Backspace forward immediately to Shell and reset engagement")
    func testTypingAndBackspacePassThrough() {
        let (view, window) = makeTerminalWithCandidates()
        guard let pipeline = view.inlinePipeline else {
            Issue.record("Expected inline pipeline to be present")
            return
        }

        // Engage first
        pipeline.moveSelection(1)
        #expect(pipeline.engagement.isEngaged)

        // Typing character "a"
        let typeEvent = makeKeyEvent(keyCode: 0, characters: "a", window: window)
        let typeResult = view.processKeyEvent(typeEvent)
        #expect(typeResult === typeEvent)
        #expect(!pipeline.engagement.isEngaged)

        // Backspace (keyCode 51): re-populate and engage
        let snapshot = CommandContextSnapshot(
            inputBuffer: "dock",
            recentCommands: ["docker ps"],
            recentOutput: ""
        )
        pipeline.request(snapshot: snapshot)
        pipeline.moveSelection(1)
        #expect(pipeline.engagement.isEngaged)
        let backspaceEvent = makeKeyEvent(keyCode: 51, window: window)
        let backspaceResult = view.processKeyEvent(backspaceEvent)
        #expect(backspaceResult === backspaceEvent)
        #expect(!pipeline.engagement.isEngaged)
    }

    // MARK: - Contract 2: Persistent Overlay (N=1) Lifecycle

    @Test("9. Candidate list overlay is persistent (N=1) and never recreated")
    func testCandidateListOverlayIsPersistentN1() {
        let (view, _) = makeTerminalWithCandidates()

        // Ensure overlay
        let overlay1 = view.ensureCandidateListOverlay()
        let overlay2 = view.ensureCandidateListOverlay()
        #expect(overlay1 === overlay2)

        // Show candidate list
        UserDefaults.standard.set(true, forKey: "ai_inline_candidate_popup")
        defer { UserDefaults.standard.removeObject(forKey: "ai_inline_candidate_popup") }

        view.showCandidateList(items: ["command a", "command b"], selectedIndex: 0)
        #expect(!overlay1.isHidden)
        #expect(overlay1.visibleRowCount == 2)

        // Hide candidate list — must hide in place, NOT remove or destroy
        view.hideCandidateList()
        #expect(overlay1.isHidden)
        #expect(overlay1.visibleRowCount == 0)

        // Showing again uses identical instance
        view.showCandidateList(items: ["command x", "command y", "command z"], selectedIndex: 1)
        #expect(!overlay1.isHidden)
        #expect(overlay1.visibleRowCount == 3)
        #expect(view.ensureCandidateListOverlay() === overlay1)
    }

    @Test("10. Candidate list overlay never accepts first responder (no focus stealing)")
    func testCandidateListOverlayNeverAcceptsFirstResponder() {
        let overlay = InlineCandidateListOverlay()
        #expect(!overlay.acceptsFirstResponder)
    }
}
