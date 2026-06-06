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
    let label: String
    @Binding var shortcut: KeyboardShortcut?
    @State private var isRecording = false
    @State private var eventMonitor: Any?

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
                        Text("Press shortcut...")
                            .foregroundStyle(.secondary)
                    } else if let shortcut {
                        shortcutLabel(shortcut)
                    } else {
                        Text("Not Set")
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minWidth: 120)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isRecording ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
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
                    .font(.system(size: 11, weight: .medium))
            }
            Text(shortcut.keyDisplay)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private func startRecording() {
        isRecording = true
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
        #if os(macOS)
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        #endif
    }
}

/// Represents a keyboard shortcut.
struct KeyboardShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: ModifierFlags

    /// Wrapper for NSEvent.ModifierFlags to make it Codable.
    struct ModifierFlags: OptionSet, Codable, Hashable {
        let rawValue: UInt

        static let shift = ModifierFlags(rawValue: 1 << 1)
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
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

/// Shortcut actions that can be configured.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTerminal
    case closeTab
    case nextTab
    case previousTab
    case find
    case settings
    case reconnect
    case clearTerminal
    case aiAssistant

    var id: String {
        rawValue
    }

    /// Default shortcut for this action.
    var defaultShortcut: KeyboardShortcut? {
        switch self {
        case .newTerminal: KeyboardShortcut(keyCode: 17, modifiers: .command) // Cmd+T
        case .closeTab: KeyboardShortcut(keyCode: 13, modifiers: .command) // Cmd+W
        case .nextTab: KeyboardShortcut(keyCode: 48, modifiers: .command) // Cmd+Tab
        case .previousTab: KeyboardShortcut(keyCode: 48, modifiers: [.command, .shift]) // Cmd+Shift+Tab
        case .find: KeyboardShortcut(keyCode: 3, modifiers: .command) // Cmd+F
        case .settings: KeyboardShortcut(keyCode: 43, modifiers: .command) // Cmd+,
        case .reconnect: KeyboardShortcut(keyCode: 15, modifiers: [.command, .shift]) // Cmd+Shift+R
        case .clearTerminal: KeyboardShortcut(keyCode: 40, modifiers: .command) // Cmd+K
        case .aiAssistant: KeyboardShortcut(keyCode: 40, modifiers: .command) // Cmd+K
        }
    }

    /// Display name for the action.
    var displayName: String {
        switch self {
        case .newTerminal: "New Terminal"
        case .closeTab: "Close Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .find: "Find"
        case .settings: "Settings"
        case .reconnect: "Reconnect"
        case .clearTerminal: "Clear Terminal"
        case .aiAssistant: "AI Assistant"
        }
    }
}
