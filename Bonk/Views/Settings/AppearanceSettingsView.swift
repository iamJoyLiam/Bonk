//
//  AppearanceSettingsView.swift
//  Bonk
//
//  Unified theme: terminal theme drives everything (app chrome + terminal).
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(I18n.self) var i18n
    @Bindable var preferences: UserPreferences
    @StateObject private var themeManager = TerminalThemeManager.shared

    var body: some View {
        Form {
            // Theme selection — one choice controls everything
            Section(i18n.t(.terminalTheme)) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    // "System" option — follows OS appearance
                    systemThemeCard()
                    // Builtin primary themes (Light, Dark, Transparent)
                    ForEach(ThemeRegistry.primary, id: \.id) { theme in
                        themeCard(theme)
                    }
                }
                .padding(.vertical, 4)
            }

            // Extra themes
            let extra = ThemeRegistry.extra
            if !extra.isEmpty {
                Section(i18n.t(.moreThemes)) {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        ForEach(extra, id: \.id) { theme in
                            themeCard(theme)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(i18n.t(.font)) {
                Picker(i18n.t(.fontFamily), selection: $preferences.fontFamily) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Menlo").tag("Menlo")
                    Text("Monaco").tag("Monaco")
                    Text("Courier New").tag("Courier New")
                    Text("JetBrains Mono").tag("JetBrains Mono")
                }
                .onChange(of: preferences.fontFamily) { _, newValue in
                    NotificationCenter.default.post(
                        name: .terminalFontDidChange,
                        object: newValue as NSString,
                        userInfo: ["fontSize": preferences.fontSize]
                    )
                }
                HStack {
                    Text(i18n.t(.fontSize))
                    Spacer()
                    // Stepper control
                    HStack(spacing: 8) {
                        Button {
                            if preferences.fontSize > 10 {
                                preferences.fontSize -= 1
                                sendFontChange()
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(preferences.fontSize > 10 ? .secondary : .tertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(preferences.fontSize <= 10)

                        Text("\(Int(preferences.fontSize))pt")
                            .font(.caption.monospaced())
                            .frame(width: 36, alignment: .center)

                        Button {
                            if preferences.fontSize < 24 {
                                preferences.fontSize += 1
                                sendFontChange()
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(preferences.fontSize < 24 ? .secondary : .tertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(preferences.fontSize >= 24)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - System Theme Card

    private func systemThemeCard() -> some View {
        let isSelected = themeManager.activeThemeID == "system"
        return Button {
            themeManager.setActive("system")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 36)
                        .overlay(
                            HStack(spacing: 0) {
                                Color.white.frame(width: 18)
                                Color.black.frame(width: 18)
                            }
                            .clipShape(.rect(cornerRadius: 6))
                        )
                }
                HStack {
                    Text(i18n.t(.system)).font(.caption2).lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Theme Card

    private func themeCard(_ theme: TerminalTheme) -> some View {
        let scheme = theme.colorScheme
        let isSelected = themeManager.activeThemeID == theme.id
        let bgColor = scheme.background.swiftUIColor
        let color0 = scheme.ansiColors[0].swiftUIColor
        let color1 = scheme.ansiColors[1].swiftUIColor
        let color2 = scheme.ansiColors[2].swiftUIColor
        let color3 = scheme.ansiColors[3].swiftUIColor

        return Button {
            themeManager.setActive(theme.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bgColor).frame(height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                        )
                    HStack(spacing: 2) {
                        strip(color0); strip(color1); strip(color2); strip(color3)
                    }.padding(.leading, 6)
                }
                HStack {
                    Text(theme.name).font(.caption2).lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func strip(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous).fill(color).frame(width: 16, height: 3)
    }

    private func sendFontChange() {
        NotificationCenter.default.post(
            name: .terminalFontDidChange,
            object: preferences.fontFamily as NSString,
            userInfo: ["fontSize": preferences.fontSize]
        )
    }
}
