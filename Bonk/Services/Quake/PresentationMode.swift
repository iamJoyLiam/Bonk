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
}
