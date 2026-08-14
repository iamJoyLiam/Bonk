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

    /// Cursor style: "block", "underline", "bar".
    @AppStorage("terminalCursorStyle")
    var cursorStyle: String = "block"

    /// Whether cursor blinks.
    @AppStorage("terminalCursorBlink")
    var cursorBlink: Bool = true

    // MARK: - Appearance Observer (macOS only)

    #if os(macOS)
        private var appearanceObservation: NSKeyValueObservation?
        private var wakeObserver: NSObjectProtocol?
        private var activeObserver: NSObjectProtocol?
        private var lastAppearance: NSAppearance?

        /// Start observing system appearance changes for "system" theme.
        func startAppearanceObservation() {
            guard appearanceObservation == nil else { return }
            lastAppearance = NSApp.effectiveAppearance
            appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                Task { @MainActor in
                    let currentAppearance = NSApp.effectiveAppearance
                    self.handleAppearanceChange(currentAppearance)
                }
            }
            // KVO on effectiveAppearance can miss changes across sleep/wake —
            // re-check when the machine wakes or the app becomes active.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleAppearanceChange(NSApp.effectiveAppearance)
                }
            }
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleAppearanceChange(NSApp.effectiveAppearance)
                }
            }
        }

        /// Stop observing system appearance changes.
        func stopAppearanceObservation() {
            appearanceObservation?.invalidate()
            appearanceObservation = nil
            if let wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            }
            if let activeObserver {
                NotificationCenter.default.removeObserver(activeObserver)
            }
            wakeObserver = nil
            activeObserver = nil
            lastAppearance = nil
        }

        private func handleAppearanceChange(_ newAppearance: NSAppearance) {
            guard activeThemeID == "system" else { return }
            guard lastAppearance != newAppearance else { return }
            lastAppearance = newAppearance
            notifyChange()
        }
    #endif

    // MARK: - Initialization

    /// Initialize and start observing if needed.
    func initializeIfNeeded() {
        #if os(macOS)
            if activeThemeID == "system" {
                startAppearanceObservation()
            }
        #endif
    }

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
        #if os(macOS)
            if id == "system" {
                startAppearanceObservation()
            } else {
                stopAppearanceObservation()
            }
        #endif
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
