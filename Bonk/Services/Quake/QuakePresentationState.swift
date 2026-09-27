//
//  QuakePresentationState.swift
//  Bonk
//
//  Shared, observable presentation state for the Quake drop-down terminal.
//

import Observation

/// Whether the Quake panel is currently on screen.
///
/// The Quake panel hosts a full terminal view for the active tab. That view
/// consumes the tab's PTY through its own output stream, feed task and render
/// engine — so while it exists, the same PTY has two independent consumers.
/// Left permanently mounted (the panel is created once at launch and merely
/// shown/hidden), it silently doubled the work of every tab switch and left
/// pane teardown with two views fighting over one session.
///
/// Publishing visibility lets the panel mount its terminal only while it is
/// actually on screen.
@MainActor
@Observable
final class QuakePresentationState {
    static let shared = QuakePresentationState()

    private(set) var isVisible = false

    private init() {}

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}
