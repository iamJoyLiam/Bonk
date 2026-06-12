//
//  TerminalThemeManager.swift
//  Bonk
//
//  Manages the active terminal theme using @AppStorage for instant propagation.
//  Posts .terminalThemeDidChange notification so terminal views update directly,
//  bypassing SwiftUI's slow reactive pipeline.
//
//  Uses ObservableObject + @Published (not @Observable) because @Observable
//  conflicts with @AppStorage property wrappers.
//

import Combine
import SwiftUI

@MainActor
final class TerminalThemeManager: ObservableObject {
    static let shared = TerminalThemeManager()

    // MARK: - Persisted Settings (@AppStorage = UserDefaults = instant)

    /// Active theme ID. "system" = follow OS appearance.
    @AppStorage("terminalThemeID")
    var activeThemeID: String = "system" {
        willSet { objectWillChange.send() }
    }

    /// Opacity for the transparent theme (0.1 - 1.0).
    @AppStorage("terminalOpacity")
    var opacity: Double = 0.85

    /// Cursor style: "block", "underline", "bar".
    @AppStorage("terminalCursorStyle")
    var cursorStyle: String = "block"

    /// Whether cursor blinks.
    @AppStorage("terminalCursorBlink")
    var cursorBlink: Bool = true

    // MARK: - Resolution

    /// Resolve the current active theme to a concrete color scheme.
    func resolve() -> TerminalColorScheme {
        resolve(id: activeThemeID)
    }

    /// Resolve any theme ID to a color scheme.
    func resolve(id: String) -> TerminalColorScheme {
        if id == "system" {
            return resolveSystem()
        }
        if id == "transparent" {
            return TransparentTheme().colorScheme(opacity: opacity)
        }
        return ThemeRegistry.theme(byID: id)?.colorScheme ?? LightTheme().colorScheme
    }

    /// Detect current OS appearance for "system" theme.
    private func resolveSystem() -> TerminalColorScheme {
        #if os(macOS)
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
            let isDark = UITraitCollection.current.userInterfaceStyle == .dark
        #endif
        return isDark ? DarkTheme().colorScheme : LightTheme().colorScheme
    }

    // MARK: - Actions

    /// Set the active theme and notify terminal views immediately.
    /// Also syncs the app chrome (window appearance) to match.
    func setActive(_ id: String) {
        activeThemeID = id
        syncAppChrome(id: id)
        notifyChange()
    }

    /// Update opacity for the transparent theme.
    func setOpacity(_ value: Double) {
        opacity = max(0.1, min(1.0, value))
        if activeThemeID == "transparent" {
            notifyChange()
        }
    }

    /// Update cursor style and notify immediately.
    func setCursorStyle(_ style: String) {
        cursorStyle = style
        NotificationCenter.default.post(name: .terminalCursorDidChange, object: nil)
    }

    /// Update cursor blink and notify immediately.
    func setCursorBlink(_ blink: Bool) {
        cursorBlink = blink
        NotificationCenter.default.post(name: .terminalCursorDidChange, object: nil)
    }

    /// Sync app chrome (window/sidebar) appearance to match the terminal theme.
    private func syncAppChrome(id: String) {
        if id == "system" {
            ThemeManager.apply("system")
            return
        }
        let isDark = ThemeRegistry.theme(byID: id)?.isDark ?? false
        ThemeManager.apply(isDark ? "dark" : "light")
        UserDefaults.standard.set(isDark, forKey: "terminalThemeIsDark")
    }

    /// Post notification so terminal Coordinators update colors directly.
    private func notifyChange() {
        let scheme = resolve()
        NotificationCenter.default.post(name: .terminalThemeDidChange, object: scheme)
    }
}
