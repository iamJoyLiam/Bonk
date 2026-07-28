//
//  PresentationMode.swift
//  Bonk
//
//  Terminal presentation mode management.
//  Session doesn't know where it's displayed - only Presentation knows.
//

import Foundation

// MARK: - Presentation Mode

/// How the terminal is currently presented to the user.
/// Session doesn't know its mode - only PresentationController manages this.
enum PresentationMode: Sendable, Equatable {
    /// Embedded in main window (default).
    case embedded

    /// Quake dropdown from screen top.
    case quake

    /// Fullscreen mode.
    case fullscreen

    /// Floating window (for future use).
    case floating

    /// Vision Pro floating space (for future use).
    case visionPro

    /// Whether the terminal is in a "temporary" mode (not main window).
    var isTemporary: Bool {
        switch self {
        case .embedded: false
        case .quake, .fullscreen, .floating, .visionPro: true
        }
    }

    /// Whether the terminal should auto-hide on focus loss.
    var shouldAutoHideOnFocusLoss: Bool {
        switch self {
        case .quake: true
        default: false
        }
    }
}

// MARK: - Presentation State

/// Current presentation state for a terminal session.
@Observable
final class PresentationState {
    /// Current presentation mode.
    var currentMode: PresentationMode = .embedded

    /// Previous mode (for transitions).
    var previousMode: PresentationMode?

    /// Whether a transition is in progress.
    var isTransitioning = false

    /// Session ID this state belongs to.
    let sessionID: UUID

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    /// Transition to a new mode.
    func transition(to mode: PresentationMode) {
        guard currentMode != mode else { return }
        previousMode = currentMode
        currentMode = mode
        isTransitioning = true
    }

    /// Complete the transition.
    func completeTransition() {
        isTransitioning = false
    }
}
