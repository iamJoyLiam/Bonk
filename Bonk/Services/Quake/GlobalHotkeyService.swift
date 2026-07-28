//
//  GlobalHotkeyService.swift
//  Bonk
//
//  Protocol for global hotkey registration and handling.
//

import AppKit
import Foundation

// MARK: - Shortcut

/// Keyboard shortcut configuration.
struct HotkeyShortcut: Sendable, Hashable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    static let defaultQuakeHotkey = HotkeyShortcut(
        keyCode: 0x32, // ~ key (`)
        modifiers: [.command]
    )

    var description: String {
        var result = ""
        if modifiers.contains(.command) { result += "⌘" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.shift) { result += "⇧" }
        result += Self.keyCodeToString(keyCode)
        return result
    }

    private static func keyCodeToString(_ keyCode: UInt32) -> String {
        switch keyCode {
        case 0x32: return "`"
        case 0x31: return "Space"
        case 0x24: return "Return"
        case 0x4C: return "Return"
        case 0x33: return "Delete"
        case 0x75: return "F5"
        case 0x7F: return "F6"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        default: return String(format: "%c", keyCode)
        }
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    static func == (lhs: HotkeyShortcut, rhs: HotkeyShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
}

// MARK: - Global Hotkey Service Protocol

/// Protocol for global hotkey registration.
@MainActor
protocol GlobalHotkeyService {
    /// Callback when hotkey is pressed.
    var onPress: (() -> Void)? { get set }

    /// Register a global hotkey.
    func register(shortcut: HotkeyShortcut) throws

    /// Unregister the current hotkey.
    func unregister()

    /// Whether the service is currently registered.
    var isRegistered: Bool { get }
}
