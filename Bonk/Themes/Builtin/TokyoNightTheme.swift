//
//  TokyoNightTheme.swift
//  Bonk
//

import Foundation

struct TokyoNightTheme: TerminalTheme {
    let id = "tokyo-night"
    let name = "Tokyo Night"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        background: RGBAColor(0.114, 0.125, 0.180),
        foreground: RGBAColor(0.780, 0.804, 0.890),
        cursor: RGBAColor(0.780, 0.804, 0.890),
        ansiColors: [
            RGBAColor(0.114, 0.125, 0.180),
            RGBAColor(0.953, 0.451, 0.490),
            RGBAColor(0.451, 0.847, 0.584),
            RGBAColor(0.976, 0.796, 0.459),
            RGBAColor(0.451, 0.647, 0.976),
            RGBAColor(0.737, 0.557, 0.976),
            RGBAColor(0.451, 0.800, 0.890),
            RGBAColor(0.780, 0.804, 0.890),
            RGBAColor(0.318, 0.337, 0.424),
            RGBAColor(0.953, 0.451, 0.490),
            RGBAColor(0.451, 0.847, 0.584),
            RGBAColor(0.976, 0.796, 0.459),
            RGBAColor(0.451, 0.647, 0.976),
            RGBAColor(0.737, 0.557, 0.976),
            RGBAColor(0.451, 0.800, 0.890),
            RGBAColor(0.906, 0.922, 0.969)
        ]
    )
}
