//
//  KeyboardSettingsView.swift
//  Bonk
//

import SwiftUI

struct KeyboardSettingsView: View {
    @Environment(I18n.self) var i18n
    @Bindable var preferences: UserPreferences
    @AppStorage("keyboard_shortcuts") private var shortcutsData: Data = .init()
    @AppStorage("right_click_paste_enabled") private var rightClickPasteEnabled = true
    @AppStorage("right_click_menu_modifier") private var rightClickMenuModifier = "command"

    /// Load saved shortcuts or use defaults.
    private var shortcuts: [String: KeyboardShortcut] {
        if let decoded = try? JSONDecoder().decode([String: KeyboardShortcut].self, from: shortcutsData) {
            return decoded
        }
        return [:]
    }

    var body: some View {
        Form {
            Section(i18n.t(.shortcuts)) {
                ForEach(ShortcutAction.allCases) { action in
                    KeyRecorderView(
                        label: i18n.t(LKey(rawValue: action.displayName) ?? .actionNewTerminal),
                        shortcut: binding(for: action)
                    )
                }
            }

            Section {
                Toggle(i18n.t(.rightClickPaste), isOn: $rightClickPasteEnabled)
                Picker(i18n.t(.rightClickPasteMenuModifier), selection: $rightClickMenuModifier) {
                    Text("⌘").tag("command")
                    Text("⌃").tag("control")
                    Text("⌥").tag("option")
                    Text("⇧").tag("shift")
                }
            } header: {
                Text(i18n.t(.input))
            }

            Section {
                Toggle(i18n.t(.optionMeta), isOn: $preferences.optionAsMeta)
                Toggle(i18n.t(.mouseReporting), isOn: $preferences.mouseReporting)
                Toggle(i18n.t(.aiDismissWithEsc), isOn: $preferences.escDismissAI)
                Toggle(i18n.t(.aiDirectSubmit), isOn: $preferences.aiDirectSubmit)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Create a binding for a shortcut action.
    private func binding(for action: ShortcutAction) -> Binding<KeyboardShortcut?> {
        Binding(
            get: {
                let allShortcuts = shortcuts
                return allShortcuts[action.rawValue] ?? action.defaultShortcut
            },
            set: { newValue in
                var allShortcuts = shortcuts
                if let newValue {
                    allShortcuts[action.rawValue] = newValue
                } else {
                    allShortcuts.removeValue(forKey: action.rawValue)
                }
                if let encoded = try? JSONEncoder().encode(allShortcuts) {
                    shortcutsData = encoded
                }
                ShortcutManager.shared.reload()
            }
        )
    }
}
