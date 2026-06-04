//
//  ThemeRegistry.swift
//  Bonk
//
//  Central registry of all available terminal themes.
//  Add new builtin themes here. Plugin themes register at runtime.
//

import Foundation

@MainActor
enum ThemeRegistry {

    // MARK: - Builtin Themes

    /// All builtin themes. Add new entries here.
    private static let builtin: [TerminalTheme] = [
        LightTheme(),
        DarkTheme(),
        TransparentTheme(),
        DraculaTheme(),
        TokyoNightTheme(),
        GruvboxDarkTheme(),
        CatppuccinMochaTheme(),
        NordTheme(),
        SolarizedDarkTheme(),
    ]

    // MARK: - Plugin Themes

    /// Themes loaded from plugins or user imports.
    private static var plugins: [TerminalTheme] = []

    /// Register a plugin theme at runtime.
    static func register(_ theme: TerminalTheme) {
        plugins.append(theme)
    }

    // MARK: - Query

    /// All available themes (builtin + plugins).
    static var all: [TerminalTheme] {
        builtin + plugins
    }

    /// Find a theme by ID.
    static func theme(byID id: String) -> TerminalTheme? {
        all.first(where: { $0.id == id })
    }

    /// Primary themes shown in the settings grid.
    static let primaryIDs: [String] = ["light", "dark"]

    /// Primary themes for the settings grid.
    static var primary: [TerminalTheme] {
        primaryIDs.compactMap { theme(byID: $0) }
    }

    /// Extra themes shown in "More Themes" section.
    /// Filters out transparent (not shown in settings grid).
    static var extra: [TerminalTheme] {
        all.filter { !primaryIDs.contains($0.id) && $0.id != "transparent" }
    }
}
