//
//  GruvboxDarkTheme.swift
//  GhostShell
//

import Foundation

struct GruvboxDarkTheme: TerminalTheme {
    let id = "gruvbox-dark"
    let name = "Gruvbox Dark"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        background: RGBAColor(0.157, 0.157, 0.137),
        foreground: RGBAColor(0.922, 0.855, 0.698),
        cursor: RGBAColor(0.922, 0.855, 0.698),
        ansiColors: [
            RGBAColor(0.157, 0.157, 0.137),
            RGBAColor(0.804, 0.141, 0.114),
            RGBAColor(0.596, 0.592, 0.102),
            RGBAColor(0.843, 0.600, 0.129),
            RGBAColor(0.314, 0.482, 0.643),
            RGBAColor(0.694, 0.306, 0.592),
            RGBAColor(0.408, 0.612, 0.416),
            RGBAColor(0.922, 0.855, 0.698),
            RGBAColor(0.467, 0.443, 0.384),
            RGBAColor(0.804, 0.141, 0.114),
            RGBAColor(0.596, 0.592, 0.102),
            RGBAColor(0.843, 0.600, 0.129),
            RGBAColor(0.314, 0.482, 0.643),
            RGBAColor(0.694, 0.306, 0.592),
            RGBAColor(0.408, 0.612, 0.416),
            RGBAColor(0.957, 0.918, 0.796),
        ]
    )
}
