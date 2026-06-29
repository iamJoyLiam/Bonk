//
//  TerminalUtils.swift
//  Bonk
//
//  Shared utilities for terminal views.
//

import Foundation
import SwiftTerm

// MARK: - Terminal Notifications

extension Notification.Name {
    static let terminalThemeDidChange = Notification.Name("com.bonk.terminalThemeDidChange")
    static let terminalCursorDidChange = Notification.Name("com.bonk.terminalCursorDidChange")
    static let terminalFontDidChange = Notification.Name("com.bonk.terminalFontDidChange")
    static let toggleAIChat = Notification.Name("com.bonk.toggleAIChat")
    static let toggleSFTP = Notification.Name("com.bonk.toggleSFTP")
    static let requestTerminalSelection = Notification.Name("com.bonk.requestTerminalSelection")
    static let terminalSelectionResponse = Notification.Name("com.bonk.terminalSelectionResponse")
    static let selectAllInTerminal = Notification.Name("com.bonk.selectAllInTerminal")
    static let focusTerminal = Notification.Name("com.bonk.focusTerminal")
}

/// Map cursor style string to SwiftTerm CursorStyle.
func mapCursorStyle(_ style: String, blink: Bool) -> SwiftTerm.CursorStyle {
    switch style {
    case "underline": blink ? .blinkUnderline : .steadyUnderline
    case "bar": blink ? .blinkBar : .steadyBar
    default: blink ? .blinkBlock : .steadyBlock
    }
}

/// Apply color scheme to a terminal view.
func applyColorScheme(to view: SwiftTerm.TerminalView, scheme: TerminalColorScheme) {
    view.nativeBackgroundColor = scheme.background.nsColor
    view.nativeForegroundColor = scheme.foreground.nsColor
    view.installColors(scheme.swiftTermColors)
}
