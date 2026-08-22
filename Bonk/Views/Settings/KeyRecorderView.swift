//
//  KeyRecorderView.swift
//  Bonk
//
//  Keyboard shortcut recorder widget.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// A SwiftUI view that records keyboard shortcuts.
struct KeyRecorderView: View {
    @Environment(I18n.self) var i18n
    let label: String
    @Binding var shortcut: KeyboardShortcut?
    @State private var isRecording = false
    @State private var eventMonitor: Any?
    /// Menu key equivalents captured before recording so they can be restored.
    @State private var savedKeyEquivalents: [SavedMenuItemShortcut] = []

    private struct SavedMenuItemShortcut {
        let item: NSMenuItem
        let keyEquivalent: String
        let modifierMask: NSEvent.ModifierFlags
    }

    var body: some View {
        HStack {
            Text(label)
                .frame(minWidth: 120, alignment: .trailing)

            Spacer()

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 4) {
                    if isRecording {
                        Text(i18n.t(.pressShortcut))
                            .foregroundStyle(.secondary)
                    } else if let shortcut {
                        shortcutLabel(shortcut)
                    } else {
                        Text(i18n.t(.notSet))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, AppStyle.spacingM)
                .padding(.vertical, AppStyle.spacingXS)
                .frame(minWidth: 120)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isRecording ? Color.accentColor.opacity(AppStyle.opacityOverlaySubtle) : Color.secondary.opacity(AppStyle.opacityOverlaySubtle))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            if shortcut != nil {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func shortcutLabel(_ shortcut: KeyboardShortcut) -> some View {
        HStack(spacing: 2) {
            ForEach(shortcut.modifierSymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: AppStyle.fontSmall, weight: .medium))
            }
            Text(shortcut.keyDisplay)
                .font(.system(size: AppStyle.fontSmall, weight: .medium))
        }
    }

    private func startRecording() {
        isRecording = true
        ShortcutManager.isRecording = true
        suppressMenuShortcuts()
        #if os(macOS)
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Require at least one modifier key
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let significantModifiers = modifiers.subtracting([.function, .numericPad])

                guard !significantModifiers.isEmpty else {
                    return event
                }

                let shortcut = KeyboardShortcut(
                    keyCode: event.keyCode,
                    modifiers: KeyboardShortcut.ModifierFlags(significantModifiers)
                )

                DispatchQueue.main.async {
                    self.shortcut = shortcut
                    stopRecording()
                }
                return nil
            }
        #endif
    }

    private func stopRecording() {
        isRecording = false
        ShortcutManager.isRecording = false
        restoreMenuShortcuts()
        #if os(macOS)
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        #endif
    }

    /// Clear every main-menu key equivalent while recording, so pressing a
    /// shortcut can never trigger an app action (SwiftUI Commands don't
    /// re-evaluate when the recording flag changes).
    private func suppressMenuShortcuts() {
        guard let menu = NSApp.mainMenu else { return }
        savedKeyEquivalents = []
        collectKeyEquivalents(from: menu)
        for entry in savedKeyEquivalents {
            entry.item.keyEquivalent = ""
            entry.item.keyEquivalentModifierMask = []
        }
    }

    private func collectKeyEquivalents(from menu: NSMenu) {
        for item in menu.items {
            if !item.keyEquivalent.isEmpty {
                savedKeyEquivalents.append(SavedMenuItemShortcut(
                    item: item,
                    keyEquivalent: item.keyEquivalent,
                    modifierMask: item.keyEquivalentModifierMask
                ))
            }
            if let submenu = item.submenu {
                collectKeyEquivalents(from: submenu)
            }
        }
    }

    private func restoreMenuShortcuts() {
        for entry in savedKeyEquivalents {
            entry.item.keyEquivalent = entry.keyEquivalent
            entry.item.keyEquivalentModifierMask = entry.modifierMask
        }
        savedKeyEquivalents = []
    }
}

/// Represents a keyboard shortcut.
struct KeyboardShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: ModifierFlags

    /// Wrapper for NSEvent.ModifierFlags to make it Codable.
    struct ModifierFlags: OptionSet, Codable, Hashable {
        let rawValue: UInt

        // NSEvent.ModifierFlags.shift is 1 << 17 — the old 1 << 1 never
        // matched, so recorded Cmd+Shift shortcuts were stored/displayed as
        // Cmd-only (and then couldn't fire).
        static let shift = ModifierFlags(rawValue: 1 << 17)
        static let control = ModifierFlags(rawValue: 1 << 18)
        static let option = ModifierFlags(rawValue: 1 << 19)
        static let command = ModifierFlags(rawValue: 1 << 20)

        #if os(macOS)
            init(_ flags: NSEvent.ModifierFlags) {
                rawValue = flags.rawValue
            }

            var nsModifierFlags: NSEvent.ModifierFlags {
                NSEvent.ModifierFlags(rawValue: rawValue)
            }
        #endif

        init(rawValue: UInt) {
            self.rawValue = rawValue
        }
    }

    /// Display symbols for the modifier keys.
    var modifierSymbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.command) { symbols.append("⌘") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        return symbols
    }

    /// Display string for the key.
    var keyDisplay: String {
        Self.keyCodeDisplayMap[keyCode] ?? String(UnicodeScalar(UInt8(keyCode)))
    }

    /// Combined display string.
    var displayString: String {
        (modifierSymbols + [keyDisplay]).joined()
    }

    /// Map of key codes to display strings.
    static let keyCodeDisplayMap: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: ".", 47: "`", 49: "Space", 50: "`",
        51: "Delete", 53: "Escape", 54: "⌘", 55: "⌘", 56: "⇧", 57: "⇪",
        58: "⌥", 59: "⌃", 60: "⇧", 61: "⌥", 62: "⌃",
        63: "Fn",
        64: "F17", 65: "F18", 66: "F19", 67: "F20", 72: "F13",
        73: "F16", 74: "F14", 75: "F10", 76: "F11", 77: "F12",
        79: "F15", 80: "F8", 81: "F9", 91: "F7", 92: "F6", 96: "F5",
        97: "F4", 98: "F3", 99: "F2", 100: "F1",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// Shortcut actions that can be configured.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTerminal
    case closeTab
    case closePane
    case nextTab
    case previousTab
    case find
    case settings
    case reconnect
    case clearTerminal
    case splitHorizontal
    case splitVertical
    case sftpBrowser
    case aiAssistant

    var id: String {
        rawValue
    }

    /// Default shortcut for this action.
    var defaultShortcut: KeyboardShortcut? {
        switch self {
        case .newTerminal: KeyboardShortcut(keyCode: 17, modifiers: .command) // Cmd+T
        case .closeTab: KeyboardShortcut(keyCode: 13, modifiers: .command) // Cmd+W
        case .closePane: KeyboardShortcut(keyCode: 13, modifiers: [.command, .shift]) // Cmd+Shift+W
        case .nextTab: KeyboardShortcut(keyCode: 48, modifiers: .command) // Cmd+Tab
        case .previousTab: KeyboardShortcut(keyCode: 48, modifiers: [.command, .shift]) // Cmd+Shift+Tab
        case .find: KeyboardShortcut(keyCode: 3, modifiers: .command) // Cmd+F
        case .settings: KeyboardShortcut(keyCode: 43, modifiers: .command) // Cmd+,
        case .reconnect: KeyboardShortcut(keyCode: 15, modifiers: [.command, .shift]) // Cmd+Shift+R
        case .clearTerminal: KeyboardShortcut(keyCode: 40, modifiers: .command) // Cmd+K
        case .splitHorizontal: KeyboardShortcut(keyCode: 2, modifiers: .command) // Cmd+D
        case .splitVertical: KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift]) // Cmd+Shift+D
        case .sftpBrowser: KeyboardShortcut(keyCode: 1, modifiers: [.command, .shift]) // Cmd+Shift+S
        case .aiAssistant: KeyboardShortcut(keyCode: 40, modifiers: [.command, .shift]) // Cmd+Shift+K
        }
    }

    /// Display name for the action.
    var displayName: String {
        switch self {
        case .newTerminal: "action_new_terminal"
        case .closeTab: "action_close_tab"
        case .closePane: "action_close_pane"
        case .nextTab: "action_next_tab"
        case .previousTab: "action_previous_tab"
        case .find: "action_find"
        case .settings: "action_settings"
        case .reconnect: "action_reconnect"
        case .clearTerminal: "action_clear_terminal"
        case .splitHorizontal: "action_split_horizontal"
        case .splitVertical: "action_split_vertical"
        case .sftpBrowser: "action_sftp_browser"
        case .aiAssistant: "action_ai_assistant"
        }
    }
}
