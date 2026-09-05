//
//  InlineArchitectureP03P04Tests.swift
//  BonkTests
//
//  Tests validating P0.3 Keyboard Router State Machine and P0.4 Context / Incremental Caches.
//

import AppKit
import Testing
@testable import Bonk

@Suite("P0.3 Inline Keyboard Router & Interaction State Machine Tests")
struct InlineKeyboardRouterTests {

    @Test("1. App shortcut takes priority and consumes event")
    func testAppShortcutIntercepted() {
        let decision = InlineKeyboardRouter.route(
            keyCode: 17, // 't'
            modifiers: .command,
            characters: "t",
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 3,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: .terminalNewTab
        )
        #expect(decision == .interceptAppShortcut(name: .terminalNewTab))
    }

    @Test("2. Search active Esc triggers search toggle")
    func testSearchActiveEsc() {
        let decision = InlineKeyboardRouter.route(
            keyCode: 53, // Esc
            modifiers: [],
            characters: nil,
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 0,
            isPopupEnabled: false,
            isSearchActive: true,
            shortcutNotification: nil
        )
        #expect(decision == .toggleSearch)
    }

    @Test("3. Passive mode: Enter passes through to Shell and cancels suggestion")
    func testPassiveEnterPassthrough() {
        let decision = InlineKeyboardRouter.route(
            keyCode: 36, // Enter
            modifiers: [],
            characters: "\r",
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 2,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(decision == .passthroughAndCancelSuggestion(reason: "enter"))
    }

    @Test("4. Engaged mode: Enter accepts the currently selected candidate")
    func testEngagedEnterAccept() {
        let decision = InlineKeyboardRouter.route(
            keyCode: 36, // Enter
            modifiers: [],
            characters: "\r",
            hasSuggestion: true,
            engagement: .engaged(index: 1),
            candidateCount: 2,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(decision == .accept)
    }

    @Test("5. Passive mode: Both Up and Down pass through to Shell history without conflict")
    func testPassiveArrowRouting() {
        let upDecision = InlineKeyboardRouter.route(
            keyCode: 126, // Up
            modifiers: [],
            characters: nil,
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 3,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(upDecision == .passthroughAndCancelSuggestion(reason: "history-nav"))

        let downDecision = InlineKeyboardRouter.route(
            keyCode: 125, // Down
            modifiers: [],
            characters: nil,
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 3,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(downDecision == .passthroughAndCancelSuggestion(reason: "history-nav"))
    }

    @Test("6. Candidate shortcuts navigate candidates, and idle shortcut is consumed to prevent garbled characters")
    func testCandidateShortcutsAndIdleSwallowing() {
        let downDecision = InlineKeyboardRouter.route(
            keyCode: 125, // Cmd+Down
            modifiers: .command,
            characters: nil,
            hasSuggestion: true,
            engagement: .engaged(index: 0),
            candidateCount: 3,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil,
            isNextCandidate: true
        )
        #expect(downDecision == .moveSelection(delta: 1))

        let upDecision = InlineKeyboardRouter.route(
            keyCode: 126, // Cmd+Up
            modifiers: .command,
            characters: nil,
            hasSuggestion: true,
            engagement: .engaged(index: 1),
            candidateCount: 3,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil,
            isPreviousCandidate: true
        )
        #expect(upDecision == .moveSelection(delta: -1))

        // When no suggestions are active, pressing candidate shortcut is consumed to prevent sending escape sequences ()
        let idleNext = InlineKeyboardRouter.route(
            keyCode: 125,
            modifiers: .command,
            characters: nil,
            hasSuggestion: false,
            engagement: .passive,
            candidateCount: 0,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil,
            isNextCandidate: true
        )
        #expect(idleNext == .consume(reason: "candidate-nav-idle"))

        let idlePrev = InlineKeyboardRouter.route(
            keyCode: 126,
            modifiers: .command,
            characters: nil,
            hasSuggestion: false,
            engagement: .passive,
            candidateCount: 0,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil,
            isPreviousCandidate: true
        )
        #expect(idlePrev == .consume(reason: "candidate-nav-idle"))

        // Plain Up/Down arrow in passive mode forwards to Shell history without conflict
        let plainUpPassive = InlineKeyboardRouter.route(
            keyCode: 126,
            modifiers: [],
            characters: nil,
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 3,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(plainUpPassive == .passthroughAndCancelSuggestion(reason: "history-nav"))

        // When at top candidate (index 0), pressing plain Up exits to Shell history
        let plainUpAtTop = InlineKeyboardRouter.route(
            keyCode: 126,
            modifiers: [],
            characters: nil,
            hasSuggestion: true,
            engagement: .engaged(index: 0),
            candidateCount: 3,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(plainUpAtTop == .passthroughAndCancelSuggestion(reason: "history-nav"))
    }

    @Test("7. Option+Down and Option+Up engage candidate selection")
    func testOptionArrowsEngageSelection() {
        let optDown = InlineKeyboardRouter.route(
            keyCode: 125,
            modifiers: .option,
            characters: nil,
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 4,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(optDown == .engageSelection(initialIndex: 0))

        let optUp = InlineKeyboardRouter.route(
            keyCode: 126,
            modifiers: .option,
            characters: nil,
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 4,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(optUp == .engageSelection(initialIndex: 3))
    }

    @Test("8. Tab accepts and Esc rejects")
    func testTabAcceptsAndEscRejects() {
        let tabDecision = InlineKeyboardRouter.route(
            keyCode: 48, // Tab
            modifiers: [],
            characters: "\t",
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 2,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(tabDecision == .accept)

        let escDecision = InlineKeyboardRouter.route(
            keyCode: 53, // Esc
            modifiers: [],
            characters: nil,
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 2,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(escDecision == .reject)
    }

    @Test("9. Typing and Backspace schedule debounced completion")
    func testTypingAndBackspaceSchedule() {
        let typeDecision = InlineKeyboardRouter.route(
            keyCode: 0,
            modifiers: [],
            characters: "a",
            hasSuggestion: true,
            engagement: .passive,
            candidateCount: 0,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(typeDecision == .passthroughAndSchedule(characters: "a"))

        let backspaceDecision = InlineKeyboardRouter.route(
            keyCode: 51,
            modifiers: [],
            characters: nil,
            hasSuggestion: false,
            engagement: .passive,
            candidateCount: 0,
            isPopupEnabled: true,
            isSearchActive: false,
            shortcutNotification: nil
        )
        #expect(backspaceDecision == .passthroughAndSchedule(characters: nil))
    }
}

@Suite("P0.4 Context Cache and Incremental Candidate Pool Tests")
@MainActor
struct InlineContextAndCandidateCacheTests {

    @Test("1. CandidatePool incremental filtering correctly filters prefix extensions")
    func testCandidatePoolIncrementalFiltering() {
        let pool = CandidatePool()
        let snap = CommandContextSnapshot(
            inputBuffer: "dock",
            recentCommands: ["docker ps", "docker build -t app .", "docker run -d nginx"],
            recentOutput: ""
        )

        // First query: "dock"
        let firstCandidates = pool.buildCandidates(
            typed: "dock",
            snapshot: snap,
            cache: nil,
            cacheKey: nil,
            isRejected: { _ in false }
        )
        #expect(!firstCandidates.isEmpty)

        // Second query: extends "dock" to "docker p"
        let incrementalCandidates = pool.buildCandidates(
            typed: "docker p",
            snapshot: snap,
            cache: nil,
            cacheKey: nil,
            isRejected: { _ in false }
        )

        #expect(!incrementalCandidates.isEmpty)
        // Must contain "docker ps"
        let fullCommands = incrementalCandidates.compactMap { $0.suggestion.fullText }
        #expect(fullCommands.contains("docker ps"))
    }
}
