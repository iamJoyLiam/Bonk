//
//  AppearanceSettingsView.swift
//  Bonk
//
//  Unified theme: terminal theme drives everything (app chrome + terminal).
//

import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject var i18n: I18n
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

                if themeManager.activeThemeID == "transparent" {
                    HStack {
                        Text(i18n.t(.opacity))
                        Spacer()
                        Text("10%").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Slider(
                            value: Binding(
                                get: { themeManager.opacity },
                                set: { themeManager.setOpacity($0) }
                            ),
                            in: 0.1...1.0,
                            step: 0.05
                        )
                        .frame(width: 160)
                        Text("100%").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Text("\(Int(themeManager.opacity * 100))%")
                            .font(.caption.monospaced())
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            // Extra themes
            let extra = ThemeRegistry.extra
            if !extra.isEmpty {
                Section(i18n.t(.moreThemes)) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
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
                    Text("10").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Slider(value: $preferences.fontSize, in: 10...24, step: 1).frame(width: 160)
                        .onChange(of: preferences.fontSize) { _, newValue in
                            NotificationCenter.default.post(
                                name: .terminalFontDidChange,
                                object: preferences.fontFamily as NSString,
                                userInfo: ["fontSize": newValue]
                            )
                        }
                    Text("24").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Text("\(Int(preferences.fontSize))pt").font(.caption.monospaced()).frame(width: 32, alignment: .trailing)
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
                    if isSelected { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.accentColor) }
                }
            }
            .padding(6)
            .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.3)) }
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Theme Card

    private func themeCard(_ theme: TerminalTheme) -> some View {
        let scheme = theme.colorScheme
        let isSelected = themeManager.activeThemeID == theme.id
        let bg = scheme.background.swiftUIColor
        let c0 = scheme.ansiColors[0].swiftUIColor
        let c1 = scheme.ansiColors[1].swiftUIColor
        let c2 = scheme.ansiColors[2].swiftUIColor
        let c3 = scheme.ansiColors[3].swiftUIColor

        return Button {
            themeManager.setActive(theme.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(bg).frame(height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                    HStack(spacing: 2) { strip(c0); strip(c1); strip(c2); strip(c3) }.padding(.leading, 6)
                }
                HStack {
                    Text(theme.name).font(.caption2).lineLimit(1)
                    Spacer()
                    if isSelected { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Color.accentColor) }
                }
            }
            .padding(6)
            .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.3)) }
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
    }

    private func strip(_ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous).fill(c).frame(width: 16, height: 3)
    }
}
