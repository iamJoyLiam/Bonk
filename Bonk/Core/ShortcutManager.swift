//
//  ShortcutManager.swift
//  Bonk
//
//  Manages keyboard shortcuts from settings.
//

import SwiftUI

/// Manages keyboard shortcuts loaded from settings.
@Observable
final class ShortcutManager: @unchecked Sendable {
    static let shared = ShortcutManager()

    /// Current shortcuts loaded from @AppStorage.
    private(set) var shortcuts: [String: KeyboardShortcut] = [:]

    /// Notification name for shortcut changes.
    static let shortcutsDidChange = Notification.Name("com.bonk.shortcutsDidChange")

    init() {
        loadShortcuts()
        // Listen for shortcut changes from settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func shortcutsChanged() {
        loadShortcuts()
        NotificationCenter.default.post(name: Self.shortcutsDidChange, object: nil)
    }

    /// Load shortcuts from @AppStorage.
    func loadShortcuts() {
        let data = UserDefaults.standard.data(forKey: "keyboard_shortcuts")
        if let data,
           let decoded = try? JSONDecoder().decode([String: KeyboardShortcut].self, from: data)
        {
            shortcuts = decoded
        }
    }

    /// Get shortcut for a specific action, converting to SwiftUI KeyboardShortcut.
    func shortcut(for action: ShortcutAction) -> SwiftUI.KeyboardShortcut {
        let custom = shortcuts[action.rawValue] ?? action.defaultShortcut
        guard let custom else {
            return SwiftUI.KeyboardShortcut(.delete, modifiers: [])
        }
        // Convert keyCode to KeyEquivalent
        guard let keyChar = Self.keyCodeToCharacter(custom.keyCode) else {
            return SwiftUI.KeyboardShortcut(.delete, modifiers: [])
        }
        // Convert modifiers
        var modifiers: EventModifiers = []
        if custom.modifiers.contains(.command) { modifiers.insert(.command) }
        if custom.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if custom.modifiers.contains(.option) { modifiers.insert(.option) }
        if custom.modifiers.contains(.control) { modifiers.insert(.control) }
        return SwiftUI.KeyboardShortcut(KeyEquivalent(keyChar), modifiers: modifiers)
    }

    /// Map keyCode to character for common keys.
    private static func keyCodeToCharacter(_ keyCode: UInt16) -> Character? {
        let map: [UInt16: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "\r",
            37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "n", 46: ".", 47: "`", 49: " ", 50: "`",
            51: "\u{8}", 53: "\u{1b}", 123: "\u{f702}", 124: "\u{f703}",
            125: "\u{f701}", 126: "\u{f700}",
        ]
        return map[keyCode]
    }
}
