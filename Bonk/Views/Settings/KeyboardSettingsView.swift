//
//  KeyboardSettingsView.swift
//  Bonk
//

import SwiftUI

struct KeyboardSettingsView: View {
    @EnvironmentObject var i18n: I18n
    @Bindable var preferences: UserPreferences
    @AppStorage("keyboard_shortcuts") private var shortcutsData: Data = .init()

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
                        label: action.displayName,
                        shortcut: binding(for: action)
                    )
                }
            }

            Section(i18n.t(.input)) {
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
                var allShortcuts = shortcuts
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
            }
        )
    }
}
