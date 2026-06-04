//
//  CatppuccinMochaTheme.swift
//  GhostShell
//

import Foundation

struct CatppuccinMochaTheme: TerminalTheme {
    let id = "catppuccin-mocha"
    let name = "Catppuccin Mocha"
    let isDark = true

    let colorScheme = TerminalColorScheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        background: RGBAColor(0.118, 0.118, 0.137),
        foreground: RGBAColor(0.871, 0.878, 0.918),
        cursor: RGBAColor(0.871, 0.878, 0.918),
        ansiColors: [
            RGBAColor(0.118, 0.118, 0.137),
            RGBAColor(0.937, 0.549, 0.580),
            RGBAColor(0.604, 0.839, 0.557),
            RGBAColor(0.980, 0.808, 0.471),
            RGBAColor(0.541, 0.682, 0.957),
            RGBAColor(0.847, 0.651, 0.957),
            RGBAColor(0.510, 0.835, 0.812),
            RGBAColor(0.871, 0.878, 0.918),
            RGBAColor(0.467, 0.443, 0.498),
            RGBAColor(0.937, 0.549, 0.580),
            RGBAColor(0.604, 0.839, 0.557),
            RGBAColor(0.980, 0.808, 0.471),
            RGBAColor(0.541, 0.682, 0.957),
            RGBAColor(0.847, 0.651, 0.957),
            RGBAColor(0.510, 0.835, 0.812),
            RGBAColor(0.937, 0.945, 0.969),
        ]
    )
}
