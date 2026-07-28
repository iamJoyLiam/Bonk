//
//  QuakeConfiguration.swift
//  Bonk
//
//  Configuration structure for Quake terminal.
//

import AppKit

// MARK: - Quake Configuration

/// Configuration for Quake dropdown terminal.
struct QuakeConfiguration: Sendable {
    /// Whether Quake mode is enabled.
    var enabled: Bool = true

    /// Keyboard shortcut for toggling Quake.
    var shortcut: HotkeyShortcut = .defaultQuakeHotkey

    /// Animation duration.
    var animationDuration: AnimationDuration = .default

    /// Height ratio (0.0 - 1.0) relative to screen height.
    var heightRatio: CGFloat = 0.5

    /// Width ratio (0.0 - 1.0) relative to screen width.
    var widthRatio: CGFloat = 1.0

    /// Window level.
    var windowLevel: NSWindow.Level = .statusBar

    /// Whether to hide window when focus is lost.
    var autoHideOnFocusLoss: Bool = true

    /// Whether to hide window when switching spaces.
    var autoHideOnSpaceChange: Bool = true

    /// ESC key behavior.
    var escBehavior: EscBehavior = .onlyWhenNoAlternateScreen
}

// MARK: - Configuration Storage Keys

extension QuakeConfiguration {
    enum Keys {
        static let enabled = "quake_enabled"
        static let hotkeyKeyCode = "quake_hotkey_keycode"
        static let hotkeyModifiers = "quake_hotkey_modifiers"
        static let heightRatio = "quake_height_ratio"
        static let widthRatio = "quake_width_ratio"
        static let autoHideOnFocusLoss = "quake_auto_hide_focus_loss"
        static let escBehavior = "quake_esc_behavior"
    }

    /// Load configuration from UserDefaults.
    static func load() -> QuakeConfiguration {
        let defaults = UserDefaults.standard
        return QuakeConfiguration(
            enabled: defaults.bool(forKey: Keys.enabled),
            shortcut: HotkeyShortcut(
                keyCode: UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode)),
                modifiers: Self.modifiersFromRaw(defaults.integer(forKey: Keys.hotkeyModifiers))
            ),
            heightRatio: CGFloat(defaults.double(forKey: Keys.heightRatio)),
            widthRatio: CGFloat(defaults.double(forKey: Keys.widthRatio)),
            autoHideOnFocusLoss: defaults.bool(forKey: Keys.autoHideOnFocusLoss),
            escBehavior: EscBehavior(rawValue: defaults.string(forKey: Keys.escBehavior) ?? "") ?? .onlyWhenNoAlternateScreen
        )
    }

    /// Save configuration to UserDefaults.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(Int(shortcut.keyCode), forKey: Keys.hotkeyKeyCode)
        defaults.set(Self.modifiersToRaw(shortcut.modifiers), forKey: Keys.hotkeyModifiers)
        defaults.set(Double(heightRatio), forKey: Keys.heightRatio)
        defaults.set(Double(widthRatio), forKey: Keys.widthRatio)
        defaults.set(autoHideOnFocusLoss, forKey: Keys.autoHideOnFocusLoss)
        defaults.set(escBehavior.rawValue, forKey: Keys.escBehavior)
    }

    // MARK: - Helpers

    private static func modifiersFromRaw(_ raw: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if raw & (1 << 20) != 0 { flags.insert(.command) }
        if raw & (1 << 19) != 0 { flags.insert(.option) }
        if raw & (1 << 18) != 0 { flags.insert(.control) }
        if raw & (1 << 17) != 0 { flags.insert(.shift) }
        return flags
    }

    private static func modifiersToRaw(_ flags: NSEvent.ModifierFlags) -> Int {
        var raw = 0
        if flags.contains(.command) { raw |= (1 << 20) }
        if flags.contains(.option) { raw |= (1 << 19) }
        if flags.contains(.control) { raw |= (1 << 18) }
        if flags.contains(.shift) { raw |= (1 << 17) }
        return raw
    }
}
