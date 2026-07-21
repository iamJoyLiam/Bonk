//
//  EditorSettingsView.swift
//  Bonk
//

import SwiftUI

struct EditorSettingsView: View {
    @Environment(I18n.self) var i18n
    @Bindable var preferences: UserPreferences
    @StateObject private var themeManager = TerminalThemeManager.shared

    /// Binding for cursor style that uses @AppStorage (instant) instead of SwiftData (slow).
    private var cursorStyleBinding: Binding<String> {
        Binding(
            get: { themeManager.cursorStyle },
            set: { themeManager.setCursorStyle($0) }
        )
    }

    /// Binding for cursor blink that uses @AppStorage (instant) instead of SwiftData (slow).
    private var cursorBlinkBinding: Binding<Bool> {
        Binding(
            get: { themeManager.cursorBlink },
            set: { themeManager.setCursorBlink($0) }
        )
    }

    var body: some View {
        Form {
            Section(i18n.t(.display)) {
                Picker(i18n.t(.cursorStyle) + ":", selection: cursorStyleBinding) {
                    Text(i18n.t(.cursorBlock)).tag("block")
                    Text(i18n.t(.cursorUnderline)).tag("underline")
                    Text(i18n.t(.cursorBar)).tag("bar")
                }
                Toggle(i18n.t(.cursorBlink), isOn: cursorBlinkBinding)
            }

            Section(i18n.t(.behavior)) {
                Toggle(i18n.t(.copyOnSelect), isOn: $preferences.copyOnSelect)
                HStack {
                    Text(i18n.t(.scrollbackLines))
                    Spacer()
                    TextField("", value: $preferences.scrollbackLines, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section(i18n.t(.scrolling)) {
                HStack {
                    Text(i18n.t(.scrollSensitivity))
                    Spacer()
                    Slider(value: $preferences.scrollSensitivity, in: 0.1...1.0, step: 0.1)
                        .frame(width: 150)
                    Text(String(format: "%.1f", preferences.scrollSensitivity))
                        .frame(width: 30)
                        .monospacedDigit()
                }
                HStack {
                    Text(i18n.t(.scrollMaxLines))
                    Spacer()
                    Stepper("\(preferences.scrollMaxLines)", value: $preferences.scrollMaxLines, in: 1...10)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
