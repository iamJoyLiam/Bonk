//
//  TerminalUtils.swift
//  GhostShell
//
//  Shared utilities for terminal views.
//

import Foundation
import SwiftTerm

// MARK: - Terminal Notifications

extension Notification.Name {
    static let terminalThemeDidChange = Notification.Name("com.ghostshell.terminalThemeDidChange")
    static let terminalCursorDidChange = Notification.Name("com.ghostshell.terminalCursorDidChange")
    static let terminalFontDidChange = Notification.Name("com.ghostshell.terminalFontDidChange")
    static let toggleAIChat = Notification.Name("com.ghostshell.toggleAIChat")
    static let requestTerminalSelection = Notification.Name("com.ghostshell.requestTerminalSelection")
    static let terminalSelectionResponse = Notification.Name("com.ghostshell.terminalSelectionResponse")
    static let selectAllInTerminal = Notification.Name("com.ghostshell.selectAllInTerminal")
    static let focusTerminal = Notification.Name("com.ghostshell.focusTerminal")
}

/// Map cursor style string to SwiftTerm CursorStyle.
func mapCursorStyle(_ style: String, blink: Bool) -> SwiftTerm.CursorStyle {
    switch style {
    case "underline": return blink ? .blinkUnderline : .steadyUnderline
    case "bar":       return blink ? .blinkBar : .steadyBar
    default:          return blink ? .blinkBlock : .steadyBlock
    }
}

/// Apply color scheme to a terminal view.
func applyColorScheme(to view: SwiftTerm.TerminalView, scheme: TerminalColorScheme) {
    view.nativeBackgroundColor = scheme.background.nsColor
    view.nativeForegroundColor = scheme.foreground.nsColor
    view.installColors(scheme.swiftTermColors)
}
