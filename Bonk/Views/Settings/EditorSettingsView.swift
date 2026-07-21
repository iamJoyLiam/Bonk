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

    /// Binding for scroll sensitivity with fallback to default.
    private var scrollSensitivityBinding: Binding<Double> {
        Binding(
            get: { preferences.scrollSensitivity ?? 0.3 },
            set: { preferences.scrollSensitivity = $0 }
        )
    }

    /// Binding for scroll max lines with fallback to default.
    private var scrollMaxLinesBinding: Binding<Int> {
        Binding(
            get: { preferences.scrollMaxLines ?? 3 },
            set: { preferences.scrollMaxLines = $0 }
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
                    Slider(value: scrollSensitivityBinding, in: 0.1...1.0, step: 0.1)
                        .frame(width: 120)
                    Text(String(format: "%.1f", preferences.scrollSensitivity ?? 0.3))
                        .frame(width: 25, alignment: .trailing)
                        .monospacedDigit()
                }
                HStack {
                    Text(i18n.t(.scrollMaxLines))
                    Spacer()
                    Button("-") {
                        let current = preferences.scrollMaxLines ?? 3
                        if current > 1 { preferences.scrollMaxLines = current - 1 }
                    }
                    .buttonStyle(.borderless)
                    Text("\(preferences.scrollMaxLines ?? 3)")
                        .frame(width: 20, alignment: .center)
                        .monospacedDigit()
                    Button("+") {
                        let current = preferences.scrollMaxLines ?? 3
                        if current < 10 { preferences.scrollMaxLines = current + 1 }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
