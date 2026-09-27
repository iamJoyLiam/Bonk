//
//  QuakePresentationStateTests.swift
//  BonkTests
//
//  The Quake panel hosts a second terminal view for the active tab. That view
//  consumes the same PTY as the main window, so it must only exist while the
//  panel is actually on screen.
//
//  These cover the state object only. Driving QuakeController.transitionTo
//  from the shared suite shows/hides a real panel and hangs the run, so the
//  controller wiring is verified by reading transitionTo, not by exercising
//  global window state here.
//

import XCTest
@testable import Bonk

@MainActor
final class QuakePresentationStateTests: XCTestCase {

    func testStartsHidden() {
        XCTAssertFalse(
            QuakePresentationState.shared.isVisible,
            "the panel is mounted at launch but must not count as visible"
        )
    }

    func testVisibilityToggles() {
        let state = QuakePresentationState.shared
        let original = state.isVisible
        defer { state.setVisible(original) }

        state.setVisible(true)
        XCTAssertTrue(state.isVisible)

        state.setVisible(false)
        XCTAssertFalse(state.isVisible)
    }

    func testRedundantSetDoesNotRepublish() {
        let state = QuakePresentationState.shared
        let original = state.isVisible
        defer { state.setVisible(original) }

        state.setVisible(true)
        state.setVisible(true)
        XCTAssertTrue(state.isVisible)
    }
}
